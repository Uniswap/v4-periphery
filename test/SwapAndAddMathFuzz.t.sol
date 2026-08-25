// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {FixedPoint96} from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {LiquidityAmounts} from "../src/libraries/LiquidityAmounts.sol";
import {ISwapAndAdd} from "../src/interfaces/ISwapAndAdd.sol";
import {IUniversalRouter} from "../src/interfaces/external/IUniversalRouter.sol";
import {PosmTestSetup} from "./shared/PosmTestSetup.sol";

/// @notice Fuzzed pins for the two load-bearing pieces of SwapAndAdd math that the deterministic sweeps and
///         the pool-config property fuzz do NOT discriminate:
///
///         1. The trim inverse (pure): across the FULL sqrt-price/width/amount domain, burning the shipped
///            round-up `dl` must free >= amountOut under v4's round-DOWN burn. The deterministic sweeps in
///            SwapAndAddTrimMath.t.sol cover engineered regimes; this walks the whole space.
///
///         2. Fee-aware sizing accuracy (behavioral): the dust returned by an add must stay price-impact-
///            small across fee tiers and budget splits. This is the one test that FAILS if the fee discount
///            in _sizeFeeAware is broken or removed — every other suite tolerates the resulting over-mint
///            because the trim claws it back and conservation still holds; only the dust (fee * swapped
///            amount, clawed back to the recipient) betrays the regression. Verified discriminating by
///            neutering the discount in src and watching this fail.
contract SwapAndAddMathFuzzTest is PosmTestSetup {
    using CurrencyLibrary for Currency;

    // ─────────────────────────── 1. trim inverse: full-domain pure fuzz ───────────────────────────

    /// @dev shipped token0 inverse, mirrored verbatim from _trim
    function _dl0(uint160 lo, uint160 su, uint256 amountOut) internal pure returns (uint256) {
        uint256 intermediate = FullMath.mulDivRoundingUp(lo, su, FixedPoint96.Q96);
        return FullMath.mulDivRoundingUp(amountOut + 1, intermediate, su - lo);
    }

    /// @dev shipped token1 inverse, mirrored verbatim from _trim
    function _dl1(uint160 sl, uint160 hi, uint256 amountOut) internal pure returns (uint256) {
        return FullMath.mulDivRoundingUp(amountOut + 1, FixedPoint96.Q96, hi - sl);
    }

    function testFuzz_trimInverse_token0_neverUnderFrees(uint160 loSeed, uint160 suSeed, uint256 amountSeed)
        public
        pure
    {
        uint160 lo = uint160(bound(loSeed, TickMath.MIN_SQRT_PRICE, TickMath.MAX_SQRT_PRICE - 1));
        uint160 su = uint160(bound(suSeed, uint256(lo) + 1, TickMath.MAX_SQRT_PRICE));
        // the debt is CORRELATED with the geometry in-contract: it can never exceed what a max-liquidity
        // position holds in token0 over [lo, su]. (Uncorrelated hugeness makes the inverse's mulDiv overflow
        // and revert — reachable only in an astronomically boundary-pinned state; see the src note.)
        uint256 maxDebt = SqrtPriceMath.getAmount0Delta(lo, su, type(uint128).max, false);
        vm.assume(maxDebt > 0);
        uint256 amountOut = bound(amountSeed, 1, maxDebt);

        uint256 dlUp = _dl0(lo, su, amountOut);
        // the shipped cap path (dlUp >= lopt) is the dust regime, pinned separately; here pin the inverse
        vm.assume(dlUp <= type(uint128).max);

        // what v4 actually frees for dlUp: rounded DOWN, the pool's favour
        uint256 freed = SqrtPriceMath.getAmount0Delta(lo, su, uint128(dlUp), false);
        assertGe(freed, amountOut, "round-up inverse must never under-free token0");
    }

    function testFuzz_trimInverse_token1_neverUnderFrees(uint160 slSeed, uint160 hiSeed, uint128 amountOut)
        public
        pure
    {
        uint160 sl = uint160(bound(slSeed, TickMath.MIN_SQRT_PRICE, TickMath.MAX_SQRT_PRICE - 1));
        uint160 hi = uint160(bound(hiSeed, uint256(sl) + 1, TickMath.MAX_SQRT_PRICE));
        vm.assume(amountOut > 0);

        uint256 dlUp = _dl1(sl, hi, amountOut);
        vm.assume(dlUp <= type(uint128).max);

        uint256 freed = SqrtPriceMath.getAmount1Delta(sl, hi, uint128(dlUp), false);
        assertGe(freed, amountOut, "round-up inverse must never under-free token1");
    }

    // ─────────────────────── 2. fee-aware sizing accuracy: dust-tightness fuzz ───────────────────────

    ISwapAndAdd zap;
    address dustRecipient = makeAddr("dustRecipient");

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();
        deployAndApprovePosm(manager);
        zap = ISwapAndAdd(
            deployCode("SwapAndAdd.sol:SwapAndAdd", abi.encode(manager, permit2, lpm, IUniversalRouter(makeAddr("ur"))))
        );
        permit2.approve(Currency.unwrap(currency0), address(zap), type(uint160).max, type(uint48).max);
        permit2.approve(Currency.unwrap(currency1), address(zap), type(uint160).max, type(uint48).max);
    }

    /// @dev With the fee discount exact, add's dust is only the reconcile swap's price impact plus rounding —
    ///      bounded well below 10bps for budgets <= 3e20 against 1e24 pool liquidity. With the discount broken
    ///      the over-mint is trimmed back and the fee on the swapped amount (up to 10% of ~half the budget)
    ///      lands in the dust instead, blowing through the bound from ~0.25bps of regression upward.
    function testFuzz_add_feeAware_dustStaysImpactSmall(uint24 feeSeed, uint256 b0Seed, uint256 b1Seed) public {
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

        // dust = everything the fresh recipient received; valued at the (still ~1) pool price
        uint256 dustValue = currency0.balanceOf(dustRecipient) + currency1.balanceOf(dustRecipient);
        uint256 budgetValue = b0 + b1;
        assertLe(dustValue * 10_000, budgetValue * 10, "dust exceeded 10bps: fee-aware sizing is inaccurate");
    }

    // ─────────────────── 3. extreme-tick sizing: token1 mirror of the token0 fuzz ───────────────────

    /// @dev single-sided token1 (range fully below spot) must deploy >= 99.9% of the feasible liquidity at any
    ///      tick — the mirror of testFuzz_add_extremeTick_fullDeployment, exercising the price<1 numeraire
    ///      branch of _sizeLiquidityWeighted with token1 budgets.
    function testFuzz_add_extremeTick_token1_fullDeployment(int24 tick, uint256 exp) public {
        tick = int24((bound(int256(tick), -799990, 800000) / 10) * 10);
        uint256 b1 = 10 ** bound(exp, 6, 30);
        uint160 spl = TickMath.getSqrtPriceAtTick(tick - 60);
        uint160 spu = TickMath.getSqrtPriceAtTick(tick);
        // uint256 replica of getLiquidityForAmount1 to pre-filter oversized/degenerate combos
        uint256 expected = FullMath.mulDiv(b1, FixedPoint96.Q96, spu - spl);
        vm.assume(expected >= 1e6 && expected < 1e33);

        PoolKey memory k = PoolKey({
            currency0: currency0, currency1: currency1, fee: 3000, tickSpacing: 10, hooks: IHooks(address(0))
        });
        manager.initialize(k, TickMath.getSqrtPriceAtTick(tick));
        MockERC20(Currency.unwrap(currency1)).mint(address(this), b1);

        uint128 feasible = LiquidityAmounts.getLiquidityForAmount1(spl, spu, b1);
        (, uint128 liq,,) = zap.add(
            ISwapAndAdd.AddParams({
                poolKey: k,
                tickLower: tick - 60,
                tickUpper: tick,
                amount0In: 0,
                amount1In: b1,
                route: "",
                routeFunding: new ISwapAndAdd.TokenAmount[](0),
                minLiquidity: uint256(feasible) * 999 / 1000,
                recipient: address(this),
                hookData: "",
                deadline: block.timestamp + 1
            })
        );
        assertGe(liq, uint128(uint256(feasible) * 999 / 1000), "full token1 budget deployed at extreme tick");
    }
}
