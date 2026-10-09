// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {IERC721} from "forge-std/interfaces/IERC721.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {ISwapAndAdd} from "../src/interfaces/ISwapAndAdd.sol";
import {IUniversalRouter} from "../src/interfaces/external/IUniversalRouter.sol";
import {SlippageCheck} from "../src/libraries/SlippageCheck.sol";
import {PosmTestSetup} from "./shared/PosmTestSetup.sol";
import {MockSwapRoute} from "./mocks/MockSwapRoute.sol";
import {MockLiquiditySandwichHook} from "./mocks/MockLiquiditySandwichHook.sol";

/// @notice Price band and amount caps. A single-sided deposit sized at a price displaced past a
///         range boundary mints more liquidity than honest execution, so `minLiquidity` cannot
///         reject it. The band gates the sizing price, the caps gate the mint.
contract SwapAndAddPriceBandTest is PosmTestSetup {
    using StateLibrary for IPoolManager;
    using CurrencyLibrary for Currency;

    ISwapAndAdd zap;
    MockSwapRoute route;

    // range above spot, so honest execution converts a token1 budget to token0
    int24 constant TL = 600;
    int24 constant TU = 6000;
    uint256 constant BUDGET1 = 5_000e18;

    uint160 BAND_LO;
    uint160 BAND_HI;

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();
        deployAndApprovePosm(manager);
        (key,) = initPoolAndAddLiquidity(currency0, currency1, IHooks(address(0)), 3000, SQRT_PRICE_1_1);
        _seedDeep(key);

        route = new MockSwapRoute(permit2);
        zap = ISwapAndAdd(
            deployCode("SwapAndAdd.sol:SwapAndAdd", abi.encode(manager, permit2, lpm, IUniversalRouter(address(route))))
        );
        seedBalance(address(this));
        MockERC20(Currency.unwrap(currency0)).mint(address(this), 1e40);
        MockERC20(Currency.unwrap(currency1)).mint(address(this), 1e40);
        MockERC20(Currency.unwrap(currency0)).approve(address(permit2), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(permit2), type(uint256).max);
        permit2.approve(Currency.unwrap(currency0), address(zap), type(uint160).max, type(uint48).max);
        permit2.approve(Currency.unwrap(currency1), address(zap), type(uint160).max, type(uint48).max);
        IERC721(address(lpm)).setApprovalForAll(address(zap), true);

        BAND_LO = uint160(uint256(SQRT_PRICE_1_1) * 99 / 100);
        BAND_HI = uint160(uint256(SQRT_PRICE_1_1) * 101 / 100);
    }

    function _seedDeep(PoolKey memory k) internal {
        modifyLiquidityRouter.modifyLiquidity(
            k, ModifyLiquidityParams({tickLower: -60_000, tickUpper: 60_000, liquidityDelta: int256(1e22), salt: 0}), ""
        );
    }

    function _pushTo(int24 tick) internal {
        (uint160 sp,,,) = manager.getSlot0(key.toId());
        uint160 target = TickMath.getSqrtPriceAtTick(tick);
        swapRouter.swap(
            key,
            SwapParams({zeroForOne: sp > target, amountSpecified: -int256(1e30), sqrtPriceLimitX96: target}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    function _addParams(uint160 lo, uint160 hi) internal view returns (ISwapAndAdd.AddParams memory) {
        return ISwapAndAdd.AddParams({
            poolKey: key,
            tickLower: TL,
            tickUpper: TU,
            amount0In: 0,
            amount1In: BUDGET1,
            route: "",
            routeFunding: new ISwapAndAdd.TokenAmount[](0),
            minLiquidity: 0,
            sqrtPriceMinX96: lo,
            sqrtPriceMaxX96: hi,
            recipient: address(this),
            hookData: "",
            deadline: block.timestamp + 1
        });
    }

    function _expectOutOfBand(uint160 lo, uint160 hi) internal {
        (uint160 live,,,) = manager.getSlot0(key.toId());
        vm.expectRevert(abi.encodeWithSelector(ISwapAndAdd.PriceOutOfBand.selector, live, lo, hi));
    }

    function _selector(bytes memory err) internal pure returns (bytes4 sel) {
        if (err.length >= 4) {
            assembly {
                sel := mload(add(err, 32))
            }
        }
    }

    // ---------------------------------------------------------------- band

    function test_add_priceBand_rejectsDisplacedSizing() public {
        _pushTo(TU + 2000);
        uint256 bal1 = currency1.balanceOf(address(this));

        _expectOutOfBand(BAND_LO, BAND_HI);
        zap.add(_addParams(BAND_LO, BAND_HI));

        assertEq(currency1.balanceOf(address(this)), bal1, "no funds moved");
    }

    /// @dev Why the floor is not enough: the displaced mint exceeds the honest liquidity.
    function test_add_floorAlone_cannotRejectDisplacedSizing() public {
        uint256 snap = vm.snapshotState();
        (, uint128 honestLiq,,) = zap.add(_addParams(0, type(uint160).max));
        vm.revertToState(snap);

        _pushTo(TU + 2000);
        ISwapAndAdd.AddParams memory p = _addParams(0, type(uint160).max);
        p.minLiquidity = honestLiq;
        (, uint128 attackedLiq, uint256 amount0,) = zap.add(p);

        assertGt(attackedLiq, honestLiq, "displaced mint clears the honest floor");
        assertEq(amount0, 0, "no reconcile swap");
    }

    function test_add_priceBand_inertWithinBand() public {
        uint256 snap = vm.snapshotState();
        (, uint128 liqNoBand, uint256 a0NoBand, uint256 a1NoBand) = zap.add(_addParams(0, type(uint160).max));
        vm.revertToState(snap);

        (, uint128 liqBand, uint256 a0Band, uint256 a1Band) = zap.add(_addParams(BAND_LO, BAND_HI));

        assertEq(liqBand, liqNoBand);
        assertEq(a0Band, a0NoBand);
        assertEq(a1Band, a1NoBand);
    }

    function _mintInRangeAndAccrue() internal returns (uint256 tokenId) {
        ISwapAndAdd.AddParams memory p = _addParams(0, type(uint160).max);
        (p.tickLower, p.tickUpper) = (-600, 600);
        (p.amount0In, p.amount1In) = (100e18, 100e18);
        (tokenId,,,) = zap.add(p);
        swap(key, true, -20e18, "");
        swap(key, false, -20e18, "");
    }

    function test_increase_priceBand_enforced() public {
        uint256 tokenId = _mintInRangeAndAccrue();
        _pushTo(TU + 2000);

        _expectOutOfBand(BAND_LO, BAND_HI);
        zap.increase(
            ISwapAndAdd.IncreaseParams({
                tokenId: tokenId,
                amount0In: 0,
                amount1In: 1e18,
                route: "",
                routeFunding: new ISwapAndAdd.TokenAmount[](0),
                minLiquidityAdded: 0,
                sqrtPriceMinX96: BAND_LO,
                sqrtPriceMaxX96: BAND_HI,
                recipient: address(this),
                hookData: "",
                deadline: block.timestamp + 1
            })
        );
    }

    function test_rebalance_priceBand_enforced() public {
        uint256 tokenId = _mintInRangeAndAccrue();
        _pushTo(TU + 2000);

        _expectOutOfBand(BAND_LO, BAND_HI);
        zap.rebalance(
            ISwapAndAdd.RebalanceParams({
                tokenId: tokenId,
                additional0: 0,
                additional1: 0,
                newTickLower: TL,
                newTickUpper: TU,
                minLiquidity: 0,
                sqrtPriceMinX96: BAND_LO,
                sqrtPriceMaxX96: BAND_HI,
                recipient: address(this),
                hookData: "",
                deadline: block.timestamp + 1,
                route: "",
                routeFunding: new ISwapAndAdd.TokenAmount[](0)
            })
        );
    }

    function test_compound_priceBand_enforced() public {
        uint256 tokenId = _mintInRangeAndAccrue();
        _pushTo(TU + 2000);

        _expectOutOfBand(BAND_LO, BAND_HI);
        zap.compound(
            ISwapAndAdd.CompoundParams({
                tokenId: tokenId,
                minLiquidityAdded: 0,
                sqrtPriceMinX96: BAND_LO,
                sqrtPriceMaxX96: BAND_HI,
                recipient: address(this),
                hookData: "",
                deadline: block.timestamp + 1,
                route: ""
            })
        );
    }

    // ---------------------------------------------------------------- amount caps

    function _sandwichPool() internal returns (PoolKey memory hk, MockLiquiditySandwichHook hook) {
        address hookAddress = address(uint160(Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG));
        vm.etch(hookAddress, address(new MockLiquiditySandwichHook()).code);
        hook = MockLiquiditySandwichHook(hookAddress);
        MockERC20(Currency.unwrap(currency0)).mint(hookAddress, 1e30);
        MockERC20(Currency.unwrap(currency1)).mint(hookAddress, 1e30);
        (hk,) = initPool(currency0, currency1, IHooks(hookAddress), 3000, int24(60), SQRT_PRICE_1_1);
        _seedDeep(hk);
    }

    /// @dev A hook moves the price inside the mint and restores it afterwards. The band is blind to
    ///      it, the amount caps reject it.
    function test_add_amountCaps_rejectSandwichInsideMint() public {
        (PoolKey memory hk, MockLiquiditySandwichHook hook) = _sandwichPool();
        // token0 budget into a range below spot: honest position is token1-only
        ISwapAndAdd.AddParams memory p = _addParams(BAND_LO, BAND_HI);
        p.poolKey = hk;
        (p.tickLower, p.tickUpper) = (-TU, -TL);
        (p.amount0In, p.amount1In) = (BUDGET1, 0);

        uint256 snap = vm.snapshotState();
        (, uint128 liq,,) = zap.add(p);
        assertGt(liq, 0, "honest add passes the caps");
        vm.revertToState(snap);

        hook.arm(manager, -TU - 2000);
        (bool ok, bytes memory err) = _tryAdd(p);
        assertFalse(ok, "sandwiched mint must revert");
        assertEq(_selector(err), SlippageCheck.MaximumAmountExceeded.selector, "caps reject the displaced mint");
    }

    function test_add_amountCaps_rejectInRangeNudge() public {
        (PoolKey memory hk, MockLiquiditySandwichHook hook) = _sandwichPool();
        ISwapAndAdd.AddParams memory p = _addParams(BAND_LO, BAND_HI);
        p.poolKey = hk;
        (p.tickLower, p.tickUpper) = (-600, 600);
        (p.amount0In, p.amount1In) = (100e18, 100e18);

        hook.arm(manager, 60);
        (bool ok, bytes memory err) = _tryAdd(p);
        assertFalse(ok);
        assertEq(_selector(err), SlippageCheck.MaximumAmountExceeded.selector);

        hook.disarm();
        (, uint128 liq,,) = zap.add(p);
        assertGt(liq, 0, "inert hook passes the caps");
    }

    function _tryAdd(ISwapAndAdd.AddParams memory p) internal returns (bool ok, bytes memory err) {
        try zap.add(p) {
            ok = true;
        } catch (bytes memory e) {
            err = e;
        }
    }

    function _mintHookPositionAndAccrue() internal returns (uint256 tokenId, MockLiquiditySandwichHook hook) {
        PoolKey memory hk;
        (hk, hook) = _sandwichPool();
        ISwapAndAdd.AddParams memory p = _addParams(BAND_LO, BAND_HI);
        p.poolKey = hk;
        (p.tickLower, p.tickUpper) = (-600, 600);
        (p.amount0In, p.amount1In) = (100e18, 100e18);
        (tokenId,,,) = zap.add(p);
        swap(hk, true, -20e18, "");
        swap(hk, false, -20e18, "");
    }

    function test_increase_amountCaps_rejectSandwichInsideIncrease() public {
        (uint256 tokenId, MockLiquiditySandwichHook hook) = _mintHookPositionAndAccrue();
        ISwapAndAdd.IncreaseParams memory p = ISwapAndAdd.IncreaseParams({
            tokenId: tokenId,
            amount0In: 100e18,
            amount1In: 100e18,
            minLiquidityAdded: 1,
            sqrtPriceMinX96: BAND_LO,
            sqrtPriceMaxX96: BAND_HI,
            recipient: address(this),
            deadline: block.timestamp + 1,
            route: "",
            routeFunding: new ISwapAndAdd.TokenAmount[](0),
            hookData: ""
        });
        uint128 beforeLiquidity = lpm.getPositionLiquidity(tokenId);
        uint256 before0 = currency0.balanceOf(address(this));
        uint256 before1 = currency1.balanceOf(address(this));

        hook.arm(manager, 60);
        vm.expectPartialRevert(SlippageCheck.MaximumAmountExceeded.selector);
        zap.increase(p);

        assertEq(lpm.getPositionLiquidity(tokenId), beforeLiquidity, "liquidity rolled back");
        assertEq(currency0.balanceOf(address(this)), before0, "token0 pull rolled back");
        assertEq(currency1.balanceOf(address(this)), before1, "token1 pull rolled back");
        hook.disarm();
        (uint128 added,,) = zap.increase(p);
        assertGt(added, 0, "inert hook allows increase with accrued fees");
        assertEq(lpm.getPositionLiquidity(tokenId), beforeLiquidity + added);
    }

    function test_compound_amountCaps_rejectSandwichInsideIncrease() public {
        (uint256 tokenId, MockLiquiditySandwichHook hook) = _mintHookPositionAndAccrue();
        ISwapAndAdd.CompoundParams memory p = ISwapAndAdd.CompoundParams({
            tokenId: tokenId,
            minLiquidityAdded: 1,
            sqrtPriceMinX96: BAND_LO,
            sqrtPriceMaxX96: BAND_HI,
            recipient: address(this),
            deadline: block.timestamp + 1,
            route: "",
            hookData: ""
        });
        uint128 beforeLiquidity = lpm.getPositionLiquidity(tokenId);
        uint256 before0 = currency0.balanceOf(address(this));
        uint256 before1 = currency1.balanceOf(address(this));

        hook.arm(manager, -60);
        vm.expectPartialRevert(SlippageCheck.MaximumAmountExceeded.selector);
        zap.compound(p);

        assertEq(lpm.getPositionLiquidity(tokenId), beforeLiquidity, "liquidity rolled back");
        assertEq(currency0.balanceOf(address(this)), before0, "token0 balance unchanged");
        assertEq(currency1.balanceOf(address(this)), before1, "token1 balance unchanged");
        hook.disarm();
        (uint128 added,,) = zap.compound(p);
        assertGt(added, 0, "fees remain available after the reverted compound");
        assertEq(lpm.getPositionLiquidity(tokenId), beforeLiquidity + added);
    }
}
