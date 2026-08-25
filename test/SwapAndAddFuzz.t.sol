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

/// @notice Property fuzz over the POOL CONFIGURATION as well as the inputs. The trim under-estimate (fixed
///         at ddcfd2b) survived the whole suite because every pool sat at price 1 and the one full-domain
///         fuzz only supplied token0-side budgets — the vulnerable configuration (low price x single-sided
///         token1) was never generated. This suite's premise: fixed pool configs are what create false
///         confidence, so NOTHING here is fixed — initial price, fee, tick spacing, depth, range and both
///         budget sides are all fuzzed, across all four operations.
///
///         THE PROPERTY: an operation either succeeds — leaving no funds at rest — or reverts with an error
///         the design explicitly allows (the whitelist in `_allowed`). v4's CurrencyNotSettled, panics and
///         wrapped low-level failures are always property violations: the contract's own errors and the
///         pool's documented limits are the only acceptable ways to fail with a non-zero minLiquidity floor.
contract SwapAndAddFuzzTest is PosmTestSetup {
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    ISwapAndAdd zap;
    MockSwapRoute route;

    bytes4 constant CURRENCY_NOT_SETTLED = 0x5212cba1;

    // budget cap (uint88 ~ 3e26 raw) and price-domain cap (|tick| <= 300_000, price ~ 1e±13): together they
    // keep the flash-take below the reserve pool's holdings, so the separate, documented PoolManager-drained limit (take
    // exceeding the PoolManager's global balance) cannot masquerade as a property violation here. The trim
    // bug's operational region (price ~1e-9, token1 from ~6.4e18) sits comfortably inside these bounds.
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

        // deep reserve pool: keeps the flash-take clear of the PoolManager-drained limit (see above).
        // Its fee is deliberately ABOVE the fuzzed fee range (0..100_000) so a fuzzed (fee, spacing) pair can
        // never collide with this key and revert PoolAlreadyInitialized. It is never swapped through.
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

    // ── fuzzed pool + range construction ────────────────────────────────────────────────────────────────

    struct Cfg {
        PoolKey key;
        int24 centre;
        int24 tl;
        int24 tu;
    }

    /// @dev a fully fuzzed pool: initial price across ±MAX_CENTRE, fee 0..10%, spacing from the common set,
    ///      seeded depth 1e18..1e26 — plus a fuzzed range of 1..127 spacings per side around (or off) spot.
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

    /// @dev Build an ordered range from two fuzzed multipliers by SORTING them rather than vm.assume-ing the
    ///      ordering: a rejection-based version throws away ~half of all inputs (and both ranges together ~75%
    ///      in the rebalance property), which exhausts the assume budget at high run counts.
    function _range(int24 centre, int24 ts, int8 aMul, int8 bMul) internal pure returns (int24 lo, int24 hi) {
        (int8 lower, int8 upper) = aMul <= bMul ? (aMul, bMul) : (bMul, aMul);
        lo = centre + int24(int256(lower)) * ts;
        hi = centre + int24(int256(upper)) * ts;
        if (lo == hi) hi += ts; // degenerate: widen by one spacing instead of rejecting the input
    }

    /// @dev VALUE-cap the fuzzed budgets: a budget's worth in the OTHER token bounds the flash-take, and
    ///      the take must stay far below the reserve pool's ~1e30-per-side holdings or the run hits the
    ///      separate, documented PoolManager-drained limit instead of the properties under test.
    ///      Clamping (not assume-ing) keeps every run meaningful at extreme prices.
    function _capBudgets(int24 centre, uint88 b0Seed, uint88 b1Seed) internal pure returns (uint256 b0, uint256 b1) {
        return _capAt(TickMath.getSqrtPriceAtTick(centre), b0Seed, b1Seed);
    }

    /// @dev The cap MUST be taken at the price that prevails when the operation runs, not at pool init: the
    ///      flash-take is sized from the live price, so a drifted pool needs re-capping or an otherwise
    ///      in-bounds budget implies an astronomical take (the drained-reserves noise this whole helper exists to exclude).
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

    /// @dev the errors an operation is DESIGNED to be able to hit on well-formed inputs; everything else —
    ///      CurrencyNotSettled above all — is a bug.
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

    // ── add: any pool config x any budgets x any range ──────────────────────────────────────────────────

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

    // ── add with a route leg: fuzzed off-venue conversion feeding the fuzzed pool ───────────────────────

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
        // an off-venue token1 -> token0 conversion at the FUZZED pool's mid, filled 50%..150% of mid, over a
        // fuzzed slice of the budget (0 = a no-op route; > b1 clamps to the full budget in the mock)
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

    /// @dev token1-per-token0 mid rate (Q96) at a tick, for the mock's pricing; clamped away from zero.
    function FullMath_rate(int24 centre) internal pure returns (uint256 r) {
        uint160 sp = TickMath.getSqrtPriceAtTick(centre);
        r = (uint256(sp) * uint256(sp)) >> 96;
        if (r == 0) r = 1;
    }

    // ── grow-in-place: mint, drift the price, then increase / compound on the fuzzed pool ───────────────

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

        // fuzzed price drift (either direction, bounded so the exact-input swap itself is well-formed);
        // fee accrual on the position rides along for free.
        if (drift != 0) {
            int256 d = int256(drift);
            try this.extSwap(c.key, d > 0, d > 0 ? d : -d) {} catch {}
        }

        // cap the increase budgets at the POST-DRIFT price — that is what its flash-take is sized from
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

    /// @dev external wrapper so a failing drift swap (e.g. pool drained to the bound) is skippable state,
    ///      not a test failure — the property under test is the zap's behavior, not the drift's.
    function extSwap(PoolKey memory k, bool zeroForOne, int256 amountIn) external {
        swap(k, zeroForOne, -amountIn, "");
    }
}
