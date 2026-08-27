// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {PosmTestSetup} from "./shared/PosmTestSetup.sol";
import {MockSwapRoute} from "./mocks/MockSwapRoute.sol";
import {ISwapAndAdd} from "../src/interfaces/ISwapAndAdd.sol";
import {IUniversalRouter} from "../src/interfaces/external/IUniversalRouter.sol";

/// @notice Regression suite for the token->liquidity inverse of `_trim`. The inverse must round up so
///         an uncapped trim always frees the flash debt. At price 1 the floored intermediate has zero
///         truncation, so the low-price pins are the load-bearing cases.
contract SwapAndAddTrimTest is PosmTestSetup {
    using CurrencyLibrary for Currency;

    ISwapAndAdd zap;
    MockSwapRoute route;

    bytes4 constant CURRENCY_NOT_SETTLED = 0x5212cba1;

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();
        deployAndApprovePosm(manager);
        (key,) = initPoolAndAddLiquidity(currency0, currency1, IHooks(address(0)), 3000, SQRT_PRICE_1_1);

        route = new MockSwapRoute(permit2);
        zap = ISwapAndAdd(
            deployCode("SwapAndAdd.sol:SwapAndAdd", abi.encode(manager, permit2, lpm, IUniversalRouter(address(route))))
        );

        MockERC20(Currency.unwrap(currency0)).mint(address(this), 1e45);
        MockERC20(Currency.unwrap(currency1)).mint(address(this), 1e45);
        seedBalance(address(this));
        MockERC20(Currency.unwrap(currency0)).approve(address(permit2), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(permit2), type(uint256).max);
        permit2.approve(Currency.unwrap(currency0), address(zap), type(uint160).max, type(uint48).max);
        permit2.approve(Currency.unwrap(currency1), address(zap), type(uint160).max, type(uint48).max);

        // deep reserve pool so the flash-take never hits the (unrelated) PoolManager-drained revert
        (PoolKey memory rk,) = initPool(currency0, currency1, IHooks(address(0)), 10000, int24(200), SQRT_PRICE_1_1);
        modifyLiquidityRouter.modifyLiquidity(
            rk,
            ModifyLiquidityParams({tickLower: -600_000, tickUpper: 600_000, liquidityDelta: int256(1e30), salt: 0}),
            ""
        );
    }

    function _p(PoolKey memory k, int24 tl, int24 tu, uint256 a0, uint256 a1, uint256 minLiq)
        internal
        view
        returns (ISwapAndAdd.AddParams memory)
    {
        return ISwapAndAdd.AddParams({
            poolKey: k,
            tickLower: tl,
            tickUpper: tu,
            amount0In: a0,
            amount1In: a1,
            route: "",
            routeFunding: new ISwapAndAdd.TokenAmount[](0),
            minLiquidity: minLiq,
            recipient: address(this),
            hookData: "",
            deadline: block.timestamp + 1
        });
    }

    function _pool(uint24 fee, int24 spacing, uint160 sqrtPrice, uint256 depth) internal returns (PoolKey memory k) {
        (k,) = initPool(currency0, currency1, IHooks(address(0)), fee, spacing, sqrtPrice);
        modifyLiquidityRouter.modifyLiquidity(
            k,
            ModifyLiquidityParams({tickLower: -600_000, tickUpper: 600_000, liquidityDelta: int256(depth), salt: 0}),
            ""
        );
    }

    function _try(PoolKey memory k, int24 tl, int24 tu, uint256 a0, uint256 a1, uint256 minLiq)
        internal
        returns (bool reverted, bytes4 sel, uint128 liq)
    {
        try zap.add(_p(k, tl, tu, a0, a1, minLiq)) returns (uint256, uint128 l, uint256, uint256) {
            liq = l;
        } catch (bytes memory data) {
            reverted = true;
            if (data.length >= 4) {
                assembly {
                    sel := mload(add(data, 32))
                }
            }
        }
    }

    // scale regime: single-sided token1 at real size

    function test_trim_largeSingleSidedToken1_succeeds() public {
        PoolKey memory k = _pool(100, 60, SQRT_PRICE_1_1, 1e34);
        (bool r, bytes4 sel, uint128 liq) = _try(k, -60, 60, 0, 4.4e30, 1);
        assertFalse(r, string.concat("must not revert; got selector ", vm.toString(sel)));
        assertGt(liq, 0, "must mint liquidity");
        assertEq(currency0.balanceOf(address(zap)), 0, "no funds at rest (0)");
        assertEq(currency1.balanceOf(address(zap)), 0, "no funds at rest (1)");
    }

    /// @dev single-sided token1 adds on a price ~1e-9 pool, where intermediate truncation is largest
    function test_trim_lowPricePool_singleSidedSweep() public {
        int24 centre = -207_240; // price ~1e-9, multiple of the spacing
        PoolKey memory k = _pool(3000, 30, TickMath.getSqrtPriceAtTick(centre), 1e27);

        // the top tier stays under the reserves of the PoolManager: at this price the token0
        // flash-take is ~1e9x the token1 budget
        uint256[5] memory amounts = [uint256(1e18), 6.4e18, 20e18, 1_000e18, 5_000e18];
        for (uint256 i = 0; i < amounts.length; i++) {
            uint256 snap = vm.snapshotState();
            (bool r, bytes4 sel, uint128 liq) = _try(k, centre - 600, centre + 600, 0, amounts[i], 1);
            assertFalse(
                r, string.concat("amount ", vm.toString(amounts[i]), " reverted with selector ", vm.toString(sel))
            );
            assertGt(liq, 0, "must mint liquidity");
            vm.revertToState(snap);
        }
    }

    // dust regime: budgets within the pool's ~1-wei mint/burn rounding toll

    /// @dev in the dust regime a non-zero floor surfaces the contract's own InsufficientLiquidity
    function test_trim_dustRegime_floorSurfacesInsufficientLiquidity() public {
        PoolKey memory k = _pool(500, 1, SQRT_PRICE_1_1, 1e24);
        (bool r, bytes4 sel,) = _try(k, -10, 6000, 259, 0, 1);
        assertTrue(r, "dust budget must revert");
        assertEq(sel, ISwapAndAdd.InsufficientLiquidity.selector, "non-zero floor must surface InsufficientLiquidity");
    }

    /// @dev a zero floor is the documented opt-out: the rounding toll surfaces as v4's CurrencyNotSettled
    function test_trim_dustRegime_zeroFloorSurfacesCurrencyNotSettled() public {
        PoolKey memory k = _pool(500, 1, SQRT_PRICE_1_1, 1e24);
        (bool r, bytes4 sel,) = _try(k, -10, 6000, 259, 0, 0);
        assertTrue(r, "dust budget must revert");
        assertEq(sel, CURRENCY_NOT_SETTLED, "zero floor lets CurrencyNotSettled surface");
    }

    // happy-path sweep across ranges and budgets

    function test_trim_happyPathSweep() public {
        PoolKey memory k = _pool(500, 10, SQRT_PRICE_1_1, 1e24);
        uint256[6] memory budgets = [uint256(1e18), 100e18, 1_000e18, 10_000e18, 1e24, 1e26];
        int24[3] memory los = [int24(-50), int24(-6000), int24(100)];
        int24[3] memory his = [int24(50), int24(6000), int24(200)];
        for (uint256 r = 0; r < los.length; r++) {
            for (uint256 i = 0; i < budgets.length; i++) {
                uint256 snap = vm.snapshotState();
                (bool rev, bytes4 sel, uint128 liq) = _try(k, los[r], his[r], 0, budgets[i], 1);
                assertFalse(
                    rev,
                    string.concat(
                        "range ",
                        vm.toString(int256(los[r])),
                        " budget ",
                        vm.toString(budgets[i]),
                        " reverted with selector ",
                        vm.toString(sel)
                    )
                );
                assertGt(liq, 0, "must mint liquidity");
                vm.revertToState(snap);
            }
        }
    }

    // fuzz: with a non-zero floor, CurrencyNotSettled is unreachable from the rounding domain

    PoolKey fuzzKeyMid;
    PoolKey fuzzKeyLow;

    function _fuzzPool(bool lowPrice) internal returns (PoolKey memory, int24 centre) {
        if (fuzzKeyMid.fee == 0) {
            fuzzKeyMid = _pool(2500, 60, SQRT_PRICE_1_1, 1e26);
            fuzzKeyLow = _pool(2500, 30, TickMath.getSqrtPriceAtTick(-207_240), 1e27);
        }
        return lowPrice ? (fuzzKeyLow, int24(-207_240)) : (fuzzKeyMid, int24(0));
    }

    function testFuzz_trim_neverUnsettledWithFloor(uint96 b0, uint96 b1, int8 loMul, int8 hiMul, bool lowPrice) public {
        (PoolKey memory k, int24 centre) = _fuzzPool(lowPrice);
        int24 tl = centre + int24(int256(loMul)) * k.tickSpacing;
        int24 tu = centre + int24(int256(hiMul)) * k.tickSpacing;
        if (tl >= tu) return;
        uint256 x0 = uint256(b0);
        uint256 x1 = uint256(b1);
        if (x0 == 0 && x1 == 0) return;
        (bool r,,) = _try(k, tl, tu, x0, x1, 1);
        // other reverts (dust floor, sizing overflow, and so on) are legitimate, CurrencyNotSettled is not
        if (r) {
            (, bytes4 sel,) = _try(k, tl, tu, x0, x1, 1);
            assertTrue(sel != CURRENCY_NOT_SETTLED, "left a currency unsettled despite floor");
        }
    }
}
