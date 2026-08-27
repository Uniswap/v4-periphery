// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {FixedPoint96} from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {IERC721} from "forge-std/interfaces/IERC721.sol";

import {LiquidityAmounts} from "../../../src/libraries/LiquidityAmounts.sol";
import {ISwapAndAdd} from "../../../src/interfaces/ISwapAndAdd.sol";
import {MockDynamicFeeHook} from "../../mocks/MockDynamicFeeHook.sol";
import {BttBase} from "./BttBase.sol";

/// @notice Sizing and geometry branches of `_planLiquidity`, driven end to end through `add`.
contract PlanLiquidityTest is BttBase {
    using StateLibrary for IPoolManager;

    function _thinPool() internal returns (PoolKey memory thin) {
        (thin,) = initPool(currency0, currency1, IHooks(address(0)), 500, SQRT_PRICE_1_1);
        modifyLiquidityRouter.modifyLiquidity(
            thin, ModifyLiquidityParams({tickLower: -6000, tickUpper: 6000, liquidityDelta: 1e15, salt: 0}), ""
        );
    }

    /// @dev A pool whose only property is its starting tick. Spacing 10 keeps extreme ranges legal.
    function _initTickPool(int24 tick) internal returns (PoolKey memory k) {
        k = PoolKey({currency0: currency0, currency1: currency1, fee: 3000, tickSpacing: 10, hooks: IHooks(address(0))});
        manager.initialize(k, TickMath.getSqrtPriceAtTick(tick));
    }

    /// @dev A single-sided token0 budget at `tick` must deploy nearly all of the feasible liquidity.
    function _assertFullDeploymentAtTick(int24 tick, uint256 b0) internal {
        PoolKey memory k = _initTickPool(tick);
        MockERC20(Currency.unwrap(currency0)).mint(address(this), b0);
        uint128 feasible = LiquidityAmounts.getLiquidityForAmount0(
            TickMath.getSqrtPriceAtTick(tick), TickMath.getSqrtPriceAtTick(tick + 60), b0
        );
        ISwapAndAdd.AddParams memory p = _addParams(tick, tick + 60, b0, 0);
        p.poolKey = k;
        p.minLiquidity = uint256(feasible) * 999 / 1000; // floor at 99.9% of feasible
        (, uint128 liq,,) = zap.add(p);
        assertGe(liq, uint128(p.minLiquidity), "full budget deployed at extreme tick");
    }

    /// @dev Land the price exactly on `boundaryTick` with a limit-clamped swap. A zeroForOne swap stores
    ///      tick = boundary - 1, a oneForZero swap stores tick = boundary.
    function _swapToExactBoundary(int24 boundaryTick, bool zeroForOne) internal returns (uint160 boundary) {
        boundary = TickMath.getSqrtPriceAtTick(boundaryTick);
        swapRouter.swap(
            key,
            SwapParams({zeroForOne: zeroForOne, amountSpecified: -100_000e18, sqrtPriceLimitX96: boundary}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    // range below spot

    function test_WhenRangeBelowSpotAndBudgetIsToken1_MintsWithoutSwap() public {
        // it mints without a swap and leaves the zap idle
        (uint256 tokenId, uint128 liq,,) = zap.add(_addParams(-1200, -660, 0, 5e18));
        assertEq(IERC721(address(lpm)).ownerOf(tokenId), address(this), "NFT owner");
        assertGt(liq, 0, "liquidity");
        _assertZapIdle();
    }

    function test_WhenRangeBelowSpotAndBudgetIsToken0_SellsIntoRange() public {
        // it sells the whole budget down into the range and mints
        (uint256 tokenId, uint128 liq,,) = zap.add(_addParams(-1200, -660, 10e18, 0));
        assertEq(IERC721(address(lpm)).ownerOf(tokenId), address(this), "NFT owner");
        assertGt(liq, 0, "liquidity");
        _assertZapIdle();
    }

    // budget beyond the depth of the pool

    function test_WhenNarrowRangeAndHugeSingleSidedBudget_StillMints() public {
        // it still mints, pushing spot past the new range
        (uint256 tokenId, uint128 liq,,) = zap.add(_addParams(-60, 60, 1_500e18, 0));
        assertEq(IERC721(address(lpm)).ownerOf(tokenId), address(this), "NFT owner");
        assertGt(liq, 0, "liquidity");
        _assertZapIdle();
    }

    function test_WhenThinPoolAndHugeSingleSidedBudget_StillMints() public {
        // it still mints against the thin depth
        ISwapAndAdd.AddParams memory p = _addParams(-60, 60, 500e18, 0);
        p.poolKey = _thinPool();
        (, uint128 liq,,) = zap.add(p);
        assertGt(liq, 0, "liquidity minted on a thin pool");
        _assertZapIdle();
    }

    function test_WhenSpotOnUpperEdgeWithToken0Budget_ReconcileFundsTheMint() public {
        // it funds the whole mint from the reconcile sell
        ISwapAndAdd.AddParams memory p = _addParams(-600, 0, 200e18, 0); // tickUpper == current tick
        p.poolKey = _thinPool();
        (, uint128 liq,,) = zap.add(p);
        assertGt(liq, 0, "liquidity minted at the upper edge");
        _assertZapIdle();
    }

    // price exactly on a boundary, where the zap sizes by sqrtPrice and the pool branches by tick

    function test_WhenPriceOnUpperBoundaryAndTickBelow_MintsWithZeroAmount0() public {
        // it degenerates the in-range amount0 to 0 and mints
        zap.add(_addParams(1e18, 1e18)); // initialize ticks +/-600 as swap landing boundaries
        uint160 boundary = _swapToExactBoundary(-600, true);

        (uint160 sp, int24 tick,,) = manager.getSlot0(key.toId());
        assertEq(sp, boundary, "engineered state: price exactly on the -600 boundary");
        assertEq(tick, -601, "engineered state: stored tick on the other side");

        (uint256 tokenId, uint128 liq,,) = zap.add(_addParams(-1200, -600, 0, 5e18));

        assertEq(IERC721(address(lpm)).ownerOf(tokenId), address(this), "NFT owner");
        assertGt(liq, 0, "liquidity minted at the inconsistent boundary");
        _assertZapIdle();
    }

    function test_WhenPriceOnLowerBoundaryAndTickAt_MintsWithZeroAmount1() public {
        // it degenerates the in-range amount1 to 0 and mints
        zap.add(_addParams(1e18, 1e18));
        uint160 boundary = _swapToExactBoundary(600, false);

        (uint160 sp, int24 tick,,) = manager.getSlot0(key.toId());
        assertEq(sp, boundary, "engineered state: price exactly on the 600 boundary");
        assertEq(tick, 600, "engineered state: tick at the boundary");

        // the boundary swap drained the token0 of the PoolManager, so seed reserves for the flash-take
        modifyLiquidityRouter.modifyLiquidity(
            key, ModifyLiquidityParams({tickLower: 600, tickUpper: 1200, liquidityDelta: 100e18, salt: 0}), ""
        );

        (uint256 tokenId, uint128 liq,,) = zap.add(_addParams(600, 1200, 5e18, 0));

        assertEq(IERC721(address(lpm)).ownerOf(tokenId), address(this), "NFT owner");
        assertGt(liq, 0, "liquidity minted at the boundary");
        _assertZapIdle();
    }

    // extreme ticks

    function test_WhenExtremeHighTickAndToken0Budget_DeploysFully() public {
        // it deploys at least 99.9% of the feasible liquidity
        _assertFullDeploymentAtTick(800000, 2e13);
    }

    function test_WhenExtremeLowTickAndToken0Budget_DeploysFully() public {
        // it deploys at least 99.9% of the feasible liquidity
        _assertFullDeploymentAtTick(-700000, 1e30);
    }

    function testFuzz_WhenExtremeTickAndToken0Budget_DeploysFully(int24 tick, uint256 exp) public {
        // it deploys at least 99.9% of the feasible liquidity
        tick = int24((bound(int256(tick), -800000, 799990) / 10) * 10);
        uint256 b0 = 10 ** bound(exp, 6, 30);
        uint160 spl = TickMath.getSqrtPriceAtTick(tick);
        uint160 spu = TickMath.getSqrtPriceAtTick(tick + 60);
        // uint256 replica of getLiquidityForAmount0, which SafeCast-reverts on oversized combos
        uint256 expected = FullMath.mulDiv(b0, FullMath.mulDiv(spl, spu, FixedPoint96.Q96), spu - spl);
        // meaningful size, under the per-tick liquidity cap for spacing 10
        vm.assume(expected >= 1e6 && expected < 1e33);
        _assertFullDeploymentAtTick(tick, b0);
    }

    /// @dev Mirror of the token0 case, through the price<1 numeraire branch.
    function testFuzz_WhenExtremeTickAndToken1Budget_DeploysFully(int24 tick, uint256 exp) public {
        // it deploys at least 99.9% of the feasible liquidity
        tick = int24((bound(int256(tick), -799990, 800000) / 10) * 10);
        uint256 b1 = 10 ** bound(exp, 6, 30);
        uint160 spl = TickMath.getSqrtPriceAtTick(tick - 60);
        uint160 spu = TickMath.getSqrtPriceAtTick(tick);
        // replica of getLiquidityForAmount1 to pre-filter degenerate combos
        uint256 expected = FullMath.mulDiv(b1, FixedPoint96.Q96, spu - spl);
        vm.assume(expected >= 1e6 && expected < 1e33);

        PoolKey memory k = _initTickPool(tick);
        MockERC20(Currency.unwrap(currency1)).mint(address(this), b1);
        uint128 feasible = LiquidityAmounts.getLiquidityForAmount1(spl, spu, b1);

        ISwapAndAdd.AddParams memory p = _addParams(tick - 60, tick, 0, b1);
        p.poolKey = k;
        p.minLiquidity = uint256(feasible) * 999 / 1000;
        (, uint128 liq,,) = zap.add(p);
        assertGe(liq, uint128(p.minLiquidity), "full token1 budget deployed at extreme tick");
    }

    /// @dev Below tick ~-665k one wei of token1 outweighs any realistic token0 budget.
    function test_WhenTwoSidedAtLowTick_ValuesToken1ViaInverseRate() public {
        // it values the token1 budget through the inverse rate
        int24 tick = -400000;
        PoolKey memory k = _initTickPool(tick);
        uint160 sp = TickMath.getSqrtPriceAtTick(tick);
        uint160 sl = TickMath.getSqrtPriceAtTick(tick - 600);
        uint160 su = TickMath.getSqrtPriceAtTick(tick + 600);
        // in-ratio budgets for ~1e18 liquidity
        uint256 b0 = SqrtPriceMath.getAmount0Delta(sp, su, 1e18, false);
        uint256 b1 = SqrtPriceMath.getAmount1Delta(sl, sp, 1e18, false);
        MockERC20(Currency.unwrap(currency0)).mint(address(this), b0);
        MockERC20(Currency.unwrap(currency1)).mint(address(this), b1);
        uint128 expected = LiquidityAmounts.getLiquidityForAmounts(sp, sl, su, b0, b1);

        ISwapAndAdd.AddParams memory p = _addParams(tick - 600, tick + 600, b0, b1);
        p.poolKey = k;
        (, uint128 liq,,) = zap.add(p);
        assertGe(liq, uint128(uint256(expected) * 999 / 1000), "token1 budget valued at a low tick");
    }

    // fees

    /// @dev Slot0 packs two directional protocol fees. Sizing must read the one for the swap direction.
    function test_WhenProtocolFeeIsSet_SizesFromTheDirectionalFee() public {
        // it sizes from the swap fee of the direction, not the packed pair
        vm.prank(feeController);
        manager.setProtocolFee(key, uint24((250 << 12) | 250)); // 0.025% both directions, packed

        (uint256 tokenId, uint128 liq,,) = zap.add(_addParams(10e18, 0));
        assertEq(IERC721(address(lpm)).ownerOf(tokenId), address(this), "NFT owner");
        assertGt(liq, 0, "minted with a directional protocol fee");

        (, uint128 liq1,,) = zap.add(_addParams(0, 10e18)); // the other surplus direction
        assertGt(liq1, 0, "minted, token1-surplus direction");
    }

    /// @dev A dynamic fee override is invisible to Slot0 sizing. The trim absorbs the difference.
    function test_WhenHookOverridesTheFee_TrimAbsorbsItAndFloorHolds() public {
        // it forwards hookData to beforeSwap and absorbs the difference in the trim
        bytes memory hookData = abi.encode("swap-and-add dynamic hook authorization");
        address hookAddress = address(uint160(Hooks.BEFORE_SWAP_FLAG));
        MockDynamicFeeHook implementation = new MockDynamicFeeHook();
        vm.etch(hookAddress, address(implementation).code);
        MockDynamicFeeHook hook = MockDynamicFeeHook(hookAddress);
        hook.configure(hookData, 0);

        (PoolKey memory dynamicKey,) = initPoolAndAddLiquidity(
            currency0, currency1, IHooks(hookAddress), LPFeeLibrary.DYNAMIC_FEE_FLAG, SQRT_PRICE_1_1
        );
        seedMoreLiquidity(dynamicKey, 1_000e18, 1_000e18);

        ISwapAndAdd.AddParams memory p = _addParams(10e18, 0);
        p.poolKey = dynamicKey;
        p.hookData = hookData;

        uint256 baselineSnapshot = vm.snapshotState();
        (, uint128 zeroFeeLiquidity,,) = zap.add(p);
        assertGt(hook.beforeSwapCalls(), 0, "reconcile forwarded hookData to beforeSwap");
        vm.revertToState(baselineSnapshot);

        hook.setFee(100_000); // 10% actual fee. Slot0 keeps its stored 0 fee.
        uint256 highFeeSnapshot = vm.snapshotState();
        (, uint128 highFeeLiquidity,,) = zap.add(p);
        assertLt(highFeeLiquidity, zeroFeeLiquidity, "the override fee caused a larger trim");
        assertGt(hook.beforeSwapCalls(), 0, "the dynamic-fee reconcile swap ran");
        _assertZapIdle();
        vm.revertToState(highFeeSnapshot);

        // it reverts with {InsufficientLiquidity} when minLiquidity is quoted at the stored fee
        p.minLiquidity = zeroFeeLiquidity;
        vm.expectPartialRevert(ISwapAndAdd.InsufficientLiquidity.selector);
        zap.add(p);
    }

    // any two-sided budget

    function testFuzz_WhenTwoSidedBudget_MintsAndLeavesTheZapIdle(uint256 a0, uint256 a1) public {
        // it mints and leaves the zap idle
        a0 = bound(a0, 1e6, 500e18);
        a1 = bound(a1, 1e6, 500e18);
        (uint256 tokenId, uint128 liq,,) = zap.add(_addParams(a0, a1));
        assertEq(IERC721(address(lpm)).ownerOf(tokenId), address(this), "NFT owner");
        assertGt(liq, 0, "liquidity");
        _assertZapIdle();
    }
}
