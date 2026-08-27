// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {Pool} from "@uniswap/v4-core/src/libraries/Pool.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {FixedPoint96} from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import {IERC721} from "forge-std/interfaces/IERC721.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {PosmTestSetup} from "./shared/PosmTestSetup.sol";
import {MockSwapRoute} from "./mocks/MockSwapRoute.sol";
import {ISwapAndAdd} from "../src/interfaces/ISwapAndAdd.sol";
import {IUniversalRouter} from "../src/interfaces/external/IUniversalRouter.sol";

/// @notice Full-domain property fuzz. Initial price, fee, tick spacing, depth, range, and both
///         budget sides are fuzzed across all four operations.
///
///         Property: an operation either succeeds and leaves no funds at rest, or reverts with an
///         error in the `_allowed` whitelist. CurrencyNotSettled, panics, and wrapped low-level
///         failures are always violations.
contract SwapAndAddFuzzTest is PosmTestSetup {
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    ISwapAndAdd zap;
    MockSwapRoute route;

    bytes4 constant CURRENCY_NOT_SETTLED = 0x5212cba1;

    // budget (uint88) and price (|tick| <= 300_000) caps keep the flash-take below the reserve
    // pool's holdings, so an out-of-scope PoolManager-drained take cannot fail the property
    int24 constant MAX_CENTRE = 300_000;

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();
        deployAndApprovePosm(manager);

        route = new MockSwapRoute(permit2);
        zap = ISwapAndAdd(
            deployCode("SwapAndAdd.sol:SwapAndAdd", abi.encode(manager, permit2, lpm, IUniversalRouter(address(route))))
        );

        MockERC20(Currency.unwrap(currency0)).mint(address(this), 1e48);
        MockERC20(Currency.unwrap(currency1)).mint(address(this), 1e48);
        seedBalance(address(this));
        MockERC20(Currency.unwrap(currency0)).approve(address(permit2), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(permit2), type(uint256).max);
        permit2.approve(Currency.unwrap(currency0), address(zap), type(uint160).max, type(uint48).max);
        permit2.approve(Currency.unwrap(currency1), address(zap), type(uint160).max, type(uint48).max);
        IERC721(address(lpm)).setApprovalForAll(address(zap), true);

        // deep reserve pool backs the flash-take. Its fee sits above the fuzzed fee range so a fuzzed
        // key cannot collide with it.
        (PoolKey memory rk,) = initPool(currency0, currency1, IHooks(address(0)), 500_000, int24(200), SQRT_PRICE_1_1);
        modifyLiquidityRouter.modifyLiquidity(
            rk,
            ModifyLiquidityParams({tickLower: -887_200, tickUpper: 887_200, liquidityDelta: int256(1e30), salt: 0}),
            ""
        );

        // route inventory for the routed-add fuzz
        MockERC20(Currency.unwrap(currency0)).mint(address(route), 1e32);
        MockERC20(Currency.unwrap(currency1)).mint(address(route), 1e32);
    }

    // fuzzed pool + range construction

    struct Cfg {
        PoolKey key;
        int24 centre;
        int24 tl;
        int24 tu;
    }

    /// @dev a fully fuzzed pool: initial price across ±MAX_CENTRE, fee 0..10%, spacing from the common set,
    ///      seeded depth 1e18..1e26, plus a fuzzed range of 1..127 spacings per side around (or off) spot.
    function _cfg(uint24 feeSeed, uint8 spacingSeed, int24 centreSeed, uint128 depthSeed, int8 loMul, int8 hiMul)
        internal
        returns (Cfg memory c)
    {
        int24[4] memory spacings = [int24(1), 10, 60, 200];
        int24 ts = spacings[spacingSeed % 4];
        c.centre = int24(bound(centreSeed, -MAX_CENTRE, MAX_CENTRE));
        c.centre = (c.centre / ts) * ts;

        uint24 fee = uint24(bound(feeSeed, 0, 100_000)); // 0 .. 10%
        (c.key,) = initPool(currency0, currency1, IHooks(address(0)), fee, ts, TickMath.getSqrtPriceAtTick(c.centre));

        uint256 depth = bound(depthSeed, 1e18, 1e26);
        int24 seedLo = ((c.centre - 60_000) / ts) * ts;
        int24 seedHi = ((c.centre + 60_000) / ts) * ts;
        modifyLiquidityRouter.modifyLiquidity(
            c.key,
            ModifyLiquidityParams({tickLower: seedLo, tickUpper: seedHi, liquidityDelta: int256(depth), salt: 0}),
            ""
        );

        (c.tl, c.tu) = _range(c.centre, ts, loMul, hiMul);
    }

    /// @dev Sort the fuzzed multipliers into an ordered range. Rejection would exhaust the assume budget.
    function _range(int24 centre, int24 ts, int8 aMul, int8 bMul) internal pure returns (int24 lo, int24 hi) {
        (int8 lower, int8 upper) = aMul <= bMul ? (aMul, bMul) : (bMul, aMul);
        lo = centre + int24(int256(lower)) * ts;
        hi = centre + int24(int256(upper)) * ts;
        if (lo == hi) hi += ts; // widen a degenerate range by one spacing
    }

    /// @dev Value-cap the budgets so the flash-take stays far below the reserve pool's ~1e30 holdings.
    function _capBudgets(int24 centre, uint88 b0Seed, uint88 b1Seed) internal pure returns (uint256 b0, uint256 b1) {
        return _capAt(TickMath.getSqrtPriceAtTick(centre), b0Seed, b1Seed);
    }

    /// @dev Cap at the live price, not the init price, because the flash-take is sized from the live price.
    function _capBudgetsAtSpot(PoolKey memory k, uint88 b0Seed, uint88 b1Seed)
        internal
        view
        returns (uint256 b0, uint256 b1)
    {
        (uint160 sp,,,) = manager.getSlot0(k.toId());
        return _capAt(sp, b0Seed, b1Seed);
    }

    function _capAt(uint160 sp, uint88 b0Seed, uint88 b1Seed) internal pure returns (uint256 b0, uint256 b1) {
        uint256 cap0 = FullMath.mulDiv(FullMath.mulDiv(1e28, FixedPoint96.Q96, sp), FixedPoint96.Q96, sp);
        uint256 cap1 = FullMath.mulDiv(FullMath.mulDiv(1e28, sp, FixedPoint96.Q96), sp, FixedPoint96.Q96);
        b0 = bound(b0Seed, 0, cap0 < type(uint88).max ? cap0 : type(uint88).max);
        b1 = bound(b1Seed, 0, cap1 < type(uint88).max ? cap1 : type(uint88).max);
    }

    /// @dev errors an operation can hit by design. Anything else, above all CurrencyNotSettled, is a bug.
    function _allowed(bytes4 sel) internal pure returns (bool) {
        return sel == ISwapAndAdd.InsufficientLiquidity.selector // the single slippage/dust gate
            || sel == ISwapAndAdd.NoFeesToCompound.selector // grow ops with nothing to deploy
            || sel == SafeCast.SafeCastOverflow.selector // sizing past uint128 liquidity
            || sel == Pool.TickLiquidityOverflow.selector // v4's own per-tick liquidity cap
            || sel == Pool.PriceLimitAlreadyExceeded.selector; // reconcile on a pool drained to the price bound
    }

    function _sel(bytes memory data) internal pure returns (bytes4 sel) {
        if (data.length >= 4) {
            assembly {
                sel := mload(add(data, 32))
            }
        }
    }

    function _noFundsAtRest(PoolKey memory k) internal view {
        assertEq(k.currency0.balanceOf(address(zap)), 0, "token0 at rest");
        assertEq(k.currency1.balanceOf(address(zap)), 0, "token1 at rest");
    }

    function _addP(Cfg memory c, uint256 a0, uint256 a1) internal view returns (ISwapAndAdd.AddParams memory) {
        return ISwapAndAdd.AddParams({
            poolKey: c.key,
            tickLower: c.tl,
            tickUpper: c.tu,
            amount0In: a0,
            amount1In: a1,
            route: "",
            routeFunding: new ISwapAndAdd.TokenAmount[](0),
            minLiquidity: 1,
            recipient: address(this),
            hookData: "",
            deadline: block.timestamp + 1
        });
    }

    // add: any pool config x any budgets x any range

    function testFuzz_add_anyPoolConfig(
        uint24 feeSeed,
        uint8 spacingSeed,
        int24 centreSeed,
        uint128 depthSeed,
        int8 loMul,
        int8 hiMul,
        uint88 b0,
        uint88 b1
    ) public {
        Cfg memory c = _cfg(feeSeed, spacingSeed, centreSeed, depthSeed, loMul, hiMul);
        (uint256 a0, uint256 a1) = _capBudgets(c.centre, b0, b1);
        vm.assume(a0 + a1 > 0);

        try zap.add(_addP(c, a0, a1)) returns (uint256 tokenId, uint128 liq, uint256, uint256) {
            assertGe(liq, 1, "floor honored");
            assertEq(IERC721(address(lpm)).ownerOf(tokenId), address(this), "user owns NFT");
        } catch (bytes memory data) {
            bytes4 sel = _sel(data);
            assertTrue(_allowed(sel), string.concat("disallowed revert: ", vm.toString(sel)));
        }
        _noFundsAtRest(c.key);
    }

    // add with a route leg: fuzzed off-venue conversion feeding the fuzzed pool

    function testFuzz_add_routed_anyPoolConfig(
        uint24 feeSeed,
        uint8 spacingSeed,
        int24 centreSeed,
        uint128 depthSeed,
        int8 loMul,
        int8 hiMul,
        uint88 b1,
        uint16 rateMultBps,
        uint88 routeInput
    ) public {
        Cfg memory c = _cfg(feeSeed, spacingSeed, centreSeed, depthSeed, loMul, hiMul);
        (, uint256 a1) = _capBudgets(c.centre, 0, b1);
        vm.assume(a1 > 0);
        // off-venue token1 -> token0 at the pool's mid, filled 50%..150% of mid, over a fuzzed slice
        // of the budget (0 = no-op route, > b1 clamps to the full budget)
        uint256 midRateX96 = FullMath_rate(c.centre);
        route.config(
            Currency.unwrap(currency1),
            Currency.unwrap(currency0),
            midRateX96,
            bound(rateMultBps, 5_000, 15_000),
            routeInput,
            false
        );

        ISwapAndAdd.AddParams memory p = _addP(c, 0, a1);
        p.route = abi.encode(bytes(""), new bytes[](0));
        try zap.add(p) returns (uint256, uint128 liq, uint256, uint256) {
            assertGe(liq, 1, "floor honored");
        } catch (bytes memory data) {
            bytes4 sel = _sel(data);
            assertTrue(_allowed(sel), string.concat("disallowed revert: ", vm.toString(sel)));
        }
        _noFundsAtRest(c.key);
    }

    /// @dev token1-per-token0 mid rate (Q96) at a tick, for the mock's pricing. Clamped away from zero.
    function FullMath_rate(int24 centre) internal pure returns (uint256 r) {
        uint160 sp = TickMath.getSqrtPriceAtTick(centre);
        r = (uint256(sp) * uint256(sp)) >> 96;
        if (r == 0) r = 1;
    }

    // grow-in-place: mint, drift the price, then increase / compound on the fuzzed pool

    function testFuzz_increase_afterDrift(
        uint24 feeSeed,
        uint8 spacingSeed,
        int24 centreSeed,
        uint128 depthSeed,
        int8 loMul,
        int8 hiMul,
        uint88 m0,
        uint88 m1,
        uint88 i0,
        uint88 i1,
        int88 drift
    ) public {
        Cfg memory c = _cfg(feeSeed, spacingSeed, centreSeed, depthSeed, loMul, hiMul);
        (uint256 c0m, uint256 c1m) = _capBudgets(c.centre, m0, m1);
        vm.assume(c0m + c1m > 0);

        uint256 tokenId;
        try zap.add(_addP(c, c0m, c1m)) returns (uint256 id, uint128, uint256, uint256) {
            tokenId = id;
        } catch (bytes memory data) {
            assertTrue(_allowed(_sel(data)), "disallowed revert on mint");
            return; // nothing minted, nothing to grow
        }

        // fuzzed price drift in either direction, which also accrues fees on the position
        if (drift != 0) {
            int256 d = int256(drift);
            try this.extSwap(c.key, d > 0, d > 0 ? d : -d) {} catch {}
        }

        // cap the increase budgets at the post-drift price
        (uint256 c0i, uint256 c1i) = _capBudgetsAtSpot(c.key, i0, i1);
        vm.assume(c0i + c1i > 0);

        try zap.increase(
            ISwapAndAdd.IncreaseParams({
                tokenId: tokenId,
                amount0In: c0i,
                amount1In: c1i,
                route: "",
                routeFunding: new ISwapAndAdd.TokenAmount[](0),
                minLiquidityAdded: 1,
                recipient: address(this),
                hookData: "",
                deadline: block.timestamp + 1
            })
        ) returns (
            uint128 added, uint256, uint256
        ) {
            assertGe(added, 1, "floor honored");
        } catch (bytes memory data) {
            bytes4 sel = _sel(data);
            assertTrue(_allowed(sel), string.concat("disallowed revert: ", vm.toString(sel)));
        }
        _noFundsAtRest(c.key);
    }

    function testFuzz_rebalance_anyNewRange(
        uint24 feeSeed,
        uint8 spacingSeed,
        int24 centreSeed,
        uint128 depthSeed,
        int8 loMul,
        int8 hiMul,
        uint88 m0,
        uint88 m1,
        int8 newLoMul,
        int8 newHiMul
    ) public {
        Cfg memory c = _cfg(feeSeed, spacingSeed, centreSeed, depthSeed, loMul, hiMul);
        (uint256 c0m, uint256 c1m) = _capBudgets(c.centre, m0, m1);
        vm.assume(c0m + c1m > 0);
        (int24 ntl, int24 ntu) = _range(c.centre, c.key.tickSpacing, newLoMul, newHiMul);

        uint256 tokenId;
        try zap.add(_addP(c, c0m, c1m)) returns (uint256 id, uint128, uint256, uint256) {
            tokenId = id;
        } catch (bytes memory data) {
            assertTrue(_allowed(_sel(data)), "disallowed revert on mint");
            return;
        }

        try zap.rebalance(
            ISwapAndAdd.RebalanceParams({
                tokenId: tokenId,
                additional0: 0,
                additional1: 0,
                newTickLower: ntl,
                newTickUpper: ntu,
                route: "",
                routeFunding: new ISwapAndAdd.TokenAmount[](0),
                minLiquidity: 1,
                recipient: address(this),
                hookData: "",
                deadline: block.timestamp + 1
            })
        ) returns (
            uint256 newId, uint128 liq, uint256, uint256
        ) {
            assertGe(liq, 1, "floor honored");
            assertEq(IERC721(address(lpm)).ownerOf(newId), address(this), "user owns new NFT");
        } catch (bytes memory data) {
            bytes4 sel = _sel(data);
            assertTrue(_allowed(sel), string.concat("disallowed revert: ", vm.toString(sel)));
        }
        _noFundsAtRest(c.key);
    }

    /// @dev external wrapper so a failed drift swap is skipped, not a test failure
    function extSwap(PoolKey memory k, bool zeroForOne, int256 amountIn) external {
        swap(k, zeroForOne, -amountIn, "");
    }

    // far edge: the reconcile sell must never land the price on or past the far edge of the range
    // with debt still owed, which raw-reverts in `_trim`. Worse-than-spot execution on a spot-sized
    // surplus keeps the post-sell price strictly inside the far edge on hookless pools.

    /// @dev A fresh pool at tick 0 whose own mint is (near-)all the liquidity, the config that gets the
    ///      sell closest to the far edge. A dust-thin full-domain band breaks the scale-invariance, so
    ///      the size of the budget varies the landing point.
    function _farEdgePool(uint24 fee, int24 spacing, uint128 extLiquidity) internal returns (PoolKey memory k) {
        k = PoolKey({
            currency0: currency0, currency1: currency1, fee: fee, tickSpacing: spacing, hooks: IHooks(address(0))
        });
        manager.initialize(k, TickMath.getSqrtPriceAtTick(0));
        if (extLiquidity > 0) {
            modifyLiquidityRouter.modifyLiquidity(
                k,
                ModifyLiquidityParams({
                    tickLower: -887_200, tickUpper: 887_200, liquidityDelta: int256(uint256(extLiquidity)), salt: 0
                }),
                ""
            );
        }
    }

    /// @dev fuzzed budgets, widths, and fees. A far-edge landing shows up as a raw revert.
    function testFuzz_farEdge_neverRawReverts(uint256 b0, uint256 b1, uint8 widthMul, uint8 feeIdx, bool ext, bool thin)
        public
    {
        uint24[4] memory fees = [uint24(0), 100, 3000, 100_000];
        int24 spacing = thin ? int24(1) : int24(10);
        int24 width = spacing * int24(uint24(bound(widthMul, 1, 200))); // down to a single tick each side
        b0 = bound(b0, 0, 1e22);
        b1 = bound(b1, 0, 1e22);
        vm.assume(b0 + b1 >= 1e12);

        PoolKey memory k = _farEdgePool(fees[feeIdx % 4], spacing, ext ? uint128(1e6) : uint128(0));
        ISwapAndAdd.AddParams memory p = ISwapAndAdd.AddParams({
            poolKey: k,
            tickLower: -width,
            tickUpper: width,
            amount0In: b0,
            amount1In: b1,
            route: "",
            routeFunding: new ISwapAndAdd.TokenAmount[](0),
            minLiquidity: 1,
            recipient: address(this),
            hookData: "",
            deadline: block.timestamp + 1
        });

        try zap.add(p) returns (uint256, uint128 liq, uint256, uint256) {
            assertGt(liq, 0, "floor honored");
            (uint160 sp,,,) = manager.getSlot0(k.toId());
            assertGt(sp, TickMath.getSqrtPriceAtTick(-width), "price reached/passed the LOWER edge");
            assertLt(sp, TickMath.getSqrtPriceAtTick(width), "price reached/passed the UPPER edge");
        } catch (bytes memory data) {
            bytes4 sel = _sel(data);
            assertTrue(
                sel == ISwapAndAdd.InsufficientLiquidity.selector || sel == CURRENCY_NOT_SETTLED,
                "raw revert from the reconcile/trim: far-edge state reached"
            );
        }
        _noFundsAtRest(k);
    }

    // fee-aware sizing: the dust must stay price-impact-small

    /// @dev With an exact fee discount the dust stays below 10 bps for budgets <= 3e20 against 1e24 pool
    ///      liquidity. A broken discount pushes the swap fee into the dust and breaks the bound.
    function testFuzz_add_feeAware_dustStaysImpactSmall(uint24 feeSeed, uint256 b0Seed, uint256 b1Seed) public {
        address dustRecipient = makeAddr("dustRecipient");
        uint24 fee = uint24(bound(feeSeed, 5000, 100_000)); // 0.5% .. 10%
        uint256 b0 = bound(b0Seed, 0, 3e20);
        uint256 b1 = bound(b1Seed, 0, 3e20);
        vm.assume(b0 + b1 >= 1e16);

        (PoolKey memory k,) = initPool(currency0, currency1, IHooks(address(0)), fee, int24(60), SQRT_PRICE_1_1);
        modifyLiquidityRouter.modifyLiquidity(
            k,
            ModifyLiquidityParams({tickLower: -600_000, tickUpper: 600_000, liquidityDelta: int256(1e24), salt: 0}),
            ""
        );

        (, uint128 liq,,) = zap.add(
            ISwapAndAdd.AddParams({
                poolKey: k,
                tickLower: -600,
                tickUpper: 600,
                amount0In: b0,
                amount1In: b1,
                route: "",
                routeFunding: new ISwapAndAdd.TokenAmount[](0),
                minLiquidity: 1,
                recipient: dustRecipient,
                hookData: "",
                deadline: block.timestamp + 1
            })
        );
        assertGt(liq, 0, "position minted");

        // dust = everything the recipient received, valued at the ~1 pool price
        uint256 dustValue = currency0.balanceOf(dustRecipient) + currency1.balanceOf(dustRecipient);
        assertLe(dustValue * 10_000, (b0 + b1) * 10, "dust exceeded 10bps: fee-aware sizing is inaccurate");
    }
}
