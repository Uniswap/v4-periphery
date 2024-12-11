// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {FixedPointMathLib} from "solmate/src/utils/FixedPointMathLib.sol";
import {Fuzzers} from "@uniswap/v4-core/src/test/Fuzzers.sol";
import {Position} from "@uniswap/v4-core/src/libraries/Position.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";

import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {DeltaResolver} from "../../src/base/DeltaResolver.sol";
import {PositionConfig} from "../shared/PositionConfig.sol";
import {SlippageCheck} from "../../src/libraries/SlippageCheck.sol";
import {IPositionManager} from "../../src/interfaces/IPositionManager.sol";
import {Actions} from "../../src/libraries/Actions.sol";
import {Planner, Plan} from "../shared/Planner.sol";
import {FeeMath} from "../shared/FeeMath.sol";
import {PosmTestSetup} from "../shared/PosmTestSetup.sol";
import {ActionConstants} from "../../src/libraries/ActionConstants.sol";

contract IncreaseLiquidityTest is Test, PosmTestSetup, Fuzzers {
    using FixedPointMathLib for uint256;
    using FeeMath for IPositionManager;
    using StateLibrary for IPoolManager;

    PoolId poolId;
    address alice = makeAddr("ALICE");
    address bob = makeAddr("BOB");

    // expresses the fee as a wad (i.e. 3000 = 0.003e18 = 0.30%)
    uint256 FEE_WAD;

    PositionConfig config;

    // Error tolerance.
    uint256 tolerance = 0.00000000001 ether;

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();

        // This is needed to receive return deltas from modifyLiquidity calls.
        deployPosmHookSavesDelta();

        (key, poolId) = initPool(currency0, currency1, IHooks(hook), 3000, SQRT_PRICE_1_1);
        FEE_WAD = uint256(key.fee).mulDivDown(FixedPointMathLib.WAD, 1_000_000);

        // Requires currency0 and currency1 to be set in base Deployers contract.
        deployAndApprovePosm(manager);

        // Give tokens to Alice and Bob.
        seedBalance(alice);
        seedBalance(bob);

        // Approve posm for Alice and bob.
        approvePosmFor(alice);
        approvePosmFor(bob);

        // define a reusable range
        config = PositionConfig({poolKey: key, tickLower: -300, tickUpper: 300});
    }

    /// @notice Increase liquidity by less than the amount of liquidity the position has earned, requiring a take
    function test_increaseLiquidity_withCollection_takePair() public {
        // Alice and Bob provide liquidity on the range
        // Alice uses her exact fees to increase liquidity (compounding)

        uint256 liquidityAlice = 3_000e18;
        uint256 liquidityBob = 1_000e18;

        // alice provides liquidity
        vm.startPrank(alice);
        uint256 tokenIdAlice = lpm.nextTokenId();
        mint(config, liquidityAlice, alice, ZERO_BYTES);
        vm.stopPrank();

        // bob provides liquidity
        vm.startPrank(bob);
        mint(config, liquidityBob, bob, ZERO_BYTES);
        vm.stopPrank();

        // donate to create fees
        uint256 amountDonate = 0.1e18;
        donateRouter.donate(key, amountDonate, amountDonate, ZERO_BYTES);

        // alice uses her half her fees to increase liquidity
        // Slight error in this calculation vs. actual fees.. TODO: Fix this.
        BalanceDelta feesOwedAlice = IPositionManager(lpm).getFeesOwed(manager, config, tokenIdAlice);
        // Note: You can alternatively calculate Alice's fees owed from the swap amount, fee on the pool, and total liquidity in that range.
        // swapAmount.mulWadDown(FEE_WAD).mulDivDown(liquidityAlice, liquidityAlice + liquidityBob);

        (uint160 sqrtPriceX96,,,) = StateLibrary.getSlot0(manager, config.poolKey.toId());
        uint256 liquidityDelta = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(config.tickLower),
            TickMath.getSqrtPriceAtTick(config.tickUpper),
            uint256(int256(feesOwedAlice.amount0() / 2)),
            uint256(int256(feesOwedAlice.amount1() / 2))
        );

        uint256 balance0BeforeAlice = currency0.balanceOf(alice);
        uint256 balance1BeforeAlice = currency1.balanceOf(alice);

        //  Set the slippage amounts to be exactly half the fees that alice is reinvesting.

        Plan memory planner = Planner.init();
        planner.add(
            Actions.INCREASE_LIQUIDITY,
            abi.encode(
                tokenIdAlice, liquidityDelta, feesOwedAlice.amount0() / 2, feesOwedAlice.amount1() / 2, ZERO_BYTES
            )
        );
        bytes memory calls = planner.finalizeModifyLiquidityWithTakePair(config.poolKey, address(alice));
        vm.startPrank(alice);
        lpm.modifyLiquidities(calls, _deadline);
        vm.stopPrank();

        // alices current balance is the balanceBefore plus half of her fees owed
        assertApproxEqAbs(
            currency0.balanceOf(alice), balance0BeforeAlice + uint256(int256(feesOwedAlice.amount0() / 2)), tolerance
        );
        assertApproxEqAbs(
            currency1.balanceOf(alice), balance1BeforeAlice + uint256(int256(feesOwedAlice.amount1() / 2)), tolerance
        );
    }

    /// @notice Increase liquidity with exact fees, taking dust
    function test_increaseLiquidity_withExactFees_take() public {
        // Alice and Bob provide liquidity on the range
        // Alice uses her exact fees to increase liquidity (compounding)

        uint256 liquidityAlice = 3_000e18;
        uint256 liquidityBob = 1_000e18;

        // alice provides liquidity
        vm.startPrank(alice);
        uint256 tokenIdAlice = lpm.nextTokenId();
        mint(config, liquidityAlice, alice, ZERO_BYTES);
        vm.stopPrank();

        // bob provides liquidity
        vm.startPrank(bob);
        mint(config, liquidityBob, bob, ZERO_BYTES);
        vm.stopPrank();

        // swap to create fees
        uint256 swapAmount = 0.001e18;
        swap(key, true, -int256(swapAmount), ZERO_BYTES);
        swap(key, false, -int256(swapAmount), ZERO_BYTES); // move the price back

        // alice uses her exact fees to increase liquidity
        // Slight error in this calculation vs. actual fees.. TODO: Fix this.
        BalanceDelta feesOwedAlice = IPositionManager(lpm).getFeesOwed(manager, config, tokenIdAlice);
        // Note: You can alternatively calculate Alice's fees owed from the swap amount, fee on the pool, and total liquidity in that range.
        // swapAmount.mulWadDown(FEE_WAD).mulDivDown(liquidityAlice, liquidityAlice + liquidityBob);

        (uint160 sqrtPriceX96,,,) = StateLibrary.getSlot0(manager, config.poolKey.toId());
        uint256 liquidityDelta = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(config.tickLower),
            TickMath.getSqrtPriceAtTick(config.tickUpper),
            uint256(int256(feesOwedAlice.amount0())),
            uint256(int256(feesOwedAlice.amount1()))
        );

        uint256 balance0BeforeAlice = currency0.balanceOf(alice);
        uint256 balance1BeforeAlice = currency1.balanceOf(alice);

        Plan memory planner = Planner.init();
        planner.add(
            Actions.INCREASE_LIQUIDITY,
            abi.encode(tokenIdAlice, liquidityDelta, feesOwedAlice.amount0(), feesOwedAlice.amount1(), ZERO_BYTES)
        );
        bytes memory calls = planner.finalizeModifyLiquidityWithClose(config.poolKey);
        vm.startPrank(alice);
        lpm.modifyLiquidities(calls, _deadline);
        vm.stopPrank();

        // alice barely spent any tokens
        assertApproxEqAbs(balance0BeforeAlice, currency0.balanceOf(alice), tolerance);
        assertApproxEqAbs(balance1BeforeAlice, currency1.balanceOf(alice), tolerance);
    }

    /// @dev Increase liquidity with exact fees, clearing dust
    function test_increaseLiquidity_withExactFees_clear() public {
        // Alice and Bob provide liquidity on the range
        // Alice uses her exact fees to increase liquidity (compounding)

        uint256 liquidityAlice = 3_000e18;
        uint256 liquidityBob = 1_000e18;

        // alice provides liquidity
        vm.startPrank(alice);
        uint256 tokenIdAlice = lpm.nextTokenId();
        mint(config, liquidityAlice, alice, ZERO_BYTES);
        vm.stopPrank();

        // bob provides liquidity
        vm.startPrank(bob);
        mint(config, liquidityBob, bob, ZERO_BYTES);
        vm.stopPrank();

        // swap to create fees
        uint256 swapAmount = 0.001e18;
        swap(key, true, -int256(swapAmount), ZERO_BYTES);
        swap(key, false, -int256(swapAmount), ZERO_BYTES); // move the price back

        // alice uses her exact fees to increase liquidity
        // Slight error in this calculation vs. actual fees.. TODO: Fix this.
        BalanceDelta feesOwedAlice = IPositionManager(lpm).getFeesOwed(manager, config, tokenIdAlice);
        // Note: You can alternatively calculate Alice's fees owed from the swap amount, fee on the pool, and total liquidity in that range.
        // swapAmount.mulWadDown(FEE_WAD).mulDivDown(liquidityAlice, liquidityAlice + liquidityBob);

        (uint160 sqrtPriceX96,,,) = StateLibrary.getSlot0(manager, config.poolKey.toId());
        uint256 liquidityDelta = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(config.tickLower),
            TickMath.getSqrtPriceAtTick(config.tickUpper),
            uint256(int256(feesOwedAlice.amount0())),
            uint256(int256(feesOwedAlice.amount1()))
        );

        uint256 balance0BeforeAlice = currency0.balanceOf(alice);
        uint256 balance1BeforeAlice = currency1.balanceOf(alice);

        Plan memory planner = Planner.init();
        planner.add(
            Actions.INCREASE_LIQUIDITY,
            abi.encode(tokenIdAlice, liquidityDelta, MAX_SLIPPAGE_INCREASE, MAX_SLIPPAGE_INCREASE, ZERO_BYTES)
        );
        planner.add(Actions.CLEAR_OR_TAKE, abi.encode(config.poolKey.currency0, 18 wei)); // alice is willing to forfeit 18 wei
        planner.add(Actions.CLEAR_OR_TAKE, abi.encode(config.poolKey.currency1, 18 wei));
        bytes memory calls = planner.encode();

        vm.prank(alice);
        lpm.modifyLiquidities(calls, _deadline);

        // alice did not spend or receive tokens
        // (alice forfeited a small amount of tokens to the pool with CLEAR)
        assertEq(currency0.balanceOf(alice), balance0BeforeAlice);
        assertEq(currency1.balanceOf(alice), balance1BeforeAlice);
    }

    // uses donate to simulate fee revenue, taking dust
    function test_increaseLiquidity_withExactFees_take_donate() public {
        // Alice and Bob provide liquidity on the range
        // Alice uses her exact fees to increase liquidity (compounding)

        uint256 liquidityAlice = 3_000e18;
        uint256 liquidityBob = 1_000e18;

        // alice provides liquidity
        vm.startPrank(alice);
        uint256 tokenIdAlice = lpm.nextTokenId();
        mint(config, liquidityAlice, alice, ZERO_BYTES);
        vm.stopPrank();

        // bob provides liquidity
        vm.startPrank(bob);
        mint(config, liquidityBob, bob, ZERO_BYTES);
        vm.stopPrank();

        // donate to create fees
        uint256 amountDonate = 0.2e18;
        donateRouter.donate(key, 0.2e18, 0.2e18, ZERO_BYTES);

        // subtract 1 cause we'd rather take than pay
        uint256 feesAmount = amountDonate.mulDivDown(liquidityAlice, liquidityAlice + liquidityBob) - 1;

        (uint160 sqrtPriceX96,,,) = StateLibrary.getSlot0(manager, config.poolKey.toId());
        uint256 liquidityDelta = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(config.tickLower),
            TickMath.getSqrtPriceAtTick(config.tickUpper),
            feesAmount,
            feesAmount
        );

        uint256 balance0BeforeAlice = currency0.balanceOf(alice);
        uint256 balance1BeforeAlice = currency1.balanceOf(alice);

        vm.startPrank(alice);
        increaseLiquidity(tokenIdAlice, config, liquidityDelta, ZERO_BYTES);
        vm.stopPrank();

        // alice barely spent any tokens
        assertApproxEqAbs(balance0BeforeAlice, currency0.balanceOf(alice), 1 wei);
        assertApproxEqAbs(balance1BeforeAlice, currency1.balanceOf(alice), 1 wei);
    }

    // uses donate to simulate fee revenue, clearing dust
    function test_increaseLiquidity_withExactFees_clear_donate() public {
        // Alice and Bob provide liquidity on the range
        // Alice uses her exact fees to increase liquidity (compounding)

        uint256 liquidityAlice = 3_000e18;
        uint256 liquidityBob = 1_000e18;

        // alice provides liquidity
        vm.startPrank(alice);
        uint256 tokenIdAlice = lpm.nextTokenId();
        mint(config, liquidityAlice, alice, ZERO_BYTES);
        vm.stopPrank();

        // bob provides liquidity
        vm.startPrank(bob);
        mint(config, liquidityBob, bob, ZERO_BYTES);
        vm.stopPrank();

        // donate to create fees
        uint256 amountDonate = 0.2e18;
        donateRouter.donate(key, 0.2e18, 0.2e18, ZERO_BYTES);

        // subtract 1 cause we'd rather take than pay
        uint256 feesAmount = amountDonate.mulDivDown(liquidityAlice, liquidityAlice + liquidityBob) - 1;

        (uint160 sqrtPriceX96,,,) = StateLibrary.getSlot0(manager, config.poolKey.toId());
        uint256 liquidityDelta = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(config.tickLower),
            TickMath.getSqrtPriceAtTick(config.tickUpper),
            feesAmount,
            feesAmount
        );

        uint256 balance0BeforeAlice = currency0.balanceOf(alice);
        uint256 balance1BeforeAlice = currency1.balanceOf(alice);

        Plan memory planner = Planner.init();
        planner.add(
            Actions.INCREASE_LIQUIDITY,
            abi.encode(tokenIdAlice, liquidityDelta, MAX_SLIPPAGE_INCREASE, MAX_SLIPPAGE_INCREASE, ZERO_BYTES)
        );
        planner.add(Actions.CLEAR_OR_TAKE, abi.encode(config.poolKey.currency0, 1 wei)); // alice is willing to forfeit 1 wei
        planner.add(Actions.CLEAR_OR_TAKE, abi.encode(config.poolKey.currency1, 1 wei));
        bytes memory calls = planner.encode();

        vm.prank(alice);
        lpm.modifyLiquidities(calls, _deadline);

        // alice did not spend or receive tokens
        // (alice forfeited a small amount of tokens to the pool with CLEAR)
        assertEq(currency0.balanceOf(alice), balance0BeforeAlice);
        assertEq(currency1.balanceOf(alice), balance1BeforeAlice);
    }

    function test_increaseLiquidity_sameRange_withExcessFees() public {
        // Alice and Bob provide liquidity on the same range
        // Alice uses half her fees to increase liquidity. The other half are collected to her wallet.
        // Bob collects all fees.
        uint256 liquidityAlice = 3_000e18;
        uint256 liquidityBob = 1_000e18;
        uint256 totalLiquidity = liquidityAlice + liquidityBob;

        // alice provides liquidity
        vm.startPrank(alice);
        uint256 tokenIdAlice = lpm.nextTokenId();
        mint(config, liquidityAlice, alice, ZERO_BYTES);
        vm.stopPrank();

        // bob provides liquidity
        vm.prank(bob);
        uint256 tokenIdBob = lpm.nextTokenId();
        mint(config, liquidityBob, bob, ZERO_BYTES);
        vm.stopPrank();

        // swap to create fees
        uint256 swapAmount = 0.001e18;
        swap(key, true, -int256(swapAmount), ZERO_BYTES);
        swap(key, false, -int256(swapAmount), ZERO_BYTES); // move the price back

        {
            // alice will use half of her fees to increase liquidity
            BalanceDelta aliceFeesOwed = IPositionManager(lpm).getFeesOwed(manager, config, tokenIdAlice);

            (uint160 sqrtPriceX96,,,) = StateLibrary.getSlot0(manager, config.poolKey.toId());
            uint256 liquidityDelta = LiquidityAmounts.getLiquidityForAmounts(
                sqrtPriceX96,
                TickMath.getSqrtPriceAtTick(config.tickLower),
                TickMath.getSqrtPriceAtTick(config.tickUpper),
                uint256(int256(aliceFeesOwed.amount0() / 2)),
                uint256(int256(aliceFeesOwed.amount1() / 2))
            );
            uint256 balance0BeforeAlice = currency0.balanceOf(alice);
            uint256 balance1BeforeAlice = currency1.balanceOf(alice);
            vm.startPrank(alice);
            increaseLiquidity(tokenIdAlice, config, liquidityDelta, ZERO_BYTES);
            vm.stopPrank();

            assertApproxEqAbs(
                currency0.balanceOf(alice) - balance0BeforeAlice,
                swapAmount.mulWadDown(FEE_WAD).mulDivDown(liquidityAlice, totalLiquidity) / 2,
                tolerance
            );
            assertApproxEqAbs(
                currency1.balanceOf(alice) - balance1BeforeAlice,
                swapAmount.mulWadDown(FEE_WAD).mulDivDown(liquidityAlice, totalLiquidity) / 2,
                tolerance
            );

            assertApproxEqAbs(
                currency0.balanceOf(alice) - balance0BeforeAlice, uint128(aliceFeesOwed.amount0()) / 2, tolerance
            );

            assertApproxEqAbs(
                currency1.balanceOf(alice) - balance1BeforeAlice, uint128(aliceFeesOwed.amount1()) / 2, tolerance
            );
        }

        {
            // bob collects his fees
            uint256 balance0BeforeBob = currency0.balanceOf(bob);
            uint256 balance1BeforeBob = currency1.balanceOf(bob);
            vm.startPrank(bob);
            collect(tokenIdBob, config, ZERO_BYTES);
            vm.stopPrank();

            assertApproxEqAbs(
                currency0.balanceOf(bob) - balance0BeforeBob,
                swapAmount.mulWadDown(FEE_WAD).mulDivDown(liquidityBob, totalLiquidity),
                tolerance
            );
            assertApproxEqAbs(
                currency1.balanceOf(bob) - balance1BeforeBob,
                swapAmount.mulWadDown(FEE_WAD).mulDivDown(liquidityBob, totalLiquidity),
                tolerance
            );

            uint256 balance0AfterBob = currency0.balanceOf(bob);
            uint256 balance1AfterBob = currency1.balanceOf(bob);
            assertApproxEqAbs(
                balance0AfterBob - balance0BeforeBob,
                swapAmount.mulWadDown(FEE_WAD).mulDivDown(liquidityBob, totalLiquidity),
                1 wei
            );
            assertApproxEqAbs(
                balance1AfterBob - balance1BeforeBob,
                swapAmount.mulWadDown(FEE_WAD).mulDivDown(liquidityBob, totalLiquidity),
                1 wei
            );
        }
    }

    function test_increaseLiquidity_withInsufficientFees() public {
        // Alice and Bob provide liquidity on the range
        // Alice uses her fees to increase liquidity. Additional funds are used by alice to increase liquidity
        uint256 liquidityAlice = 3_000e18;
        uint256 liquidityBob = 1_000e18;
        uint256 totalLiquidity = liquidityAlice + liquidityBob;

        // alice provides liquidity
        vm.startPrank(alice);
        uint256 tokenIdAlice = lpm.nextTokenId();
        mint(config, liquidityAlice, alice, ZERO_BYTES);
        vm.stopPrank();

        // bob provides liquidity
        vm.startPrank(bob);
        uint256 tokenIdBob = lpm.nextTokenId();
        mint(config, liquidityBob, bob, ZERO_BYTES);
        vm.stopPrank();

        // swap to create fees
        uint256 swapAmount = 0.001e18;
        swap(key, true, -int256(swapAmount), ZERO_BYTES);
        swap(key, false, -int256(swapAmount), ZERO_BYTES); // move the price back

        // alice will use all of her fees + additional capital to increase liquidity
        BalanceDelta feesOwed = IPositionManager(lpm).getFeesOwed(manager, config, tokenIdAlice);

        {
            (uint160 sqrtPriceX96,,,) = StateLibrary.getSlot0(manager, config.poolKey.toId());
            uint256 liquidityDelta = LiquidityAmounts.getLiquidityForAmounts(
                sqrtPriceX96,
                TickMath.getSqrtPriceAtTick(config.tickLower),
                TickMath.getSqrtPriceAtTick(config.tickUpper),
                uint256(int256(feesOwed.amount0())) * 2,
                uint256(int256(feesOwed.amount1())) * 2
            );

            uint256 balance0BeforeAlice = currency0.balanceOf(alice);
            uint256 balance1BeforeAlice = currency1.balanceOf(alice);
            vm.startPrank(alice);
            increaseLiquidity(tokenIdAlice, config, liquidityDelta, ZERO_BYTES);
            vm.stopPrank();
            uint256 balance0AfterAlice = currency0.balanceOf(alice);
            uint256 balance1AfterAlice = currency1.balanceOf(alice);

            // Alice owed feesOwed amount in 0 and 1 because she places feesOwed * 2 back into the pool.
            assertApproxEqAbs(balance0BeforeAlice - balance0AfterAlice, uint256(int256(feesOwed.amount0())), tolerance);
            assertApproxEqAbs(balance1BeforeAlice - balance1AfterAlice, uint256(int256(feesOwed.amount1())), tolerance);
        }

        {
            // bob collects his fees
            uint256 balance0BeforeBob = currency0.balanceOf(bob);
            uint256 balance1BeforeBob = currency1.balanceOf(bob);
            vm.startPrank(bob);
            collect(tokenIdBob, config, ZERO_BYTES);
            vm.stopPrank();
            uint256 balance0AfterBob = currency0.balanceOf(bob);
            uint256 balance1AfterBob = currency1.balanceOf(bob);
            assertApproxEqAbs(
                balance0AfterBob - balance0BeforeBob,
                swapAmount.mulWadDown(FEE_WAD).mulDivDown(liquidityBob, totalLiquidity),
                tolerance
            );
            assertApproxEqAbs(
                balance1AfterBob - balance1BeforeBob,
                swapAmount.mulWadDown(FEE_WAD).mulDivDown(liquidityBob, totalLiquidity),
                tolerance
            );
        }
    }

    function test_increaseLiquidity_slippage_revertAmount0() public {
        // increasing liquidity with strict slippage parameters (amount0) will revert
        uint256 tokenId = lpm.nextTokenId();
        mint(config, 100e18, ActionConstants.MSG_SENDER, ZERO_BYTES);

        uint128 newLiquidity = 100e18;
        (uint256 amount0,) = LiquidityAmounts.getAmountsForLiquidity(
            SQRT_PRICE_1_1,
            TickMath.getSqrtPriceAtTick(config.tickLower),
            TickMath.getSqrtPriceAtTick(config.tickUpper),
            newLiquidity
        );
        // revert since amount0Max is too low
        bytes memory calls = getIncreaseEncoded(tokenId, config, newLiquidity, 1 wei, type(uint128).max, ZERO_BYTES);
        vm.expectRevert(abi.encodeWithSelector(SlippageCheck.MaximumAmountExceeded.selector, 1 wei, amount0 + 1));
        lpm.modifyLiquidities(calls, _deadline);
    }

    function test_increaseLiquidity_slippage_revertAmount1() public {
        // increasing liquidity with strict slippage parameters (amount1) will revert
        uint256 tokenId = lpm.nextTokenId();
        mint(config, 100e18, ActionConstants.MSG_SENDER, ZERO_BYTES);

        uint128 newLiquidity = 100e18;
        (, uint256 amount1) = LiquidityAmounts.getAmountsForLiquidity(
            SQRT_PRICE_1_1,
            TickMath.getSqrtPriceAtTick(config.tickLower),
            TickMath.getSqrtPriceAtTick(config.tickUpper),
            newLiquidity
        );
        // revert since amount1Max is too low
        bytes memory calls = getIncreaseEncoded(tokenId, config, newLiquidity, type(uint128).max, 1 wei, ZERO_BYTES);
        vm.expectRevert(abi.encodeWithSelector(SlippageCheck.MaximumAmountExceeded.selector, 1 wei, amount1 + 1));
        lpm.modifyLiquidities(calls, _deadline);
    }

    function test_increaseLiquidity_slippage_exactDoesNotRevert() public {
        // increasing liquidity with perfect slippage parameters does not revert
        uint256 tokenId = lpm.nextTokenId();
        mint(config, 100e18, ActionConstants.MSG_SENDER, ZERO_BYTES);

        uint128 newLiquidity = 10e18;
        (uint256 amount0, uint256 amount1) = LiquidityAmounts.getAmountsForLiquidity(
            SQRT_PRICE_1_1,
            TickMath.getSqrtPriceAtTick(config.tickLower),
            TickMath.getSqrtPriceAtTick(config.tickUpper),
            newLiquidity
        );
        assertEq(amount0, amount1); // symmetric liquidity addition
        uint128 slippage = uint128(amount0) + 1;

        bytes memory calls = getIncreaseEncoded(tokenId, config, newLiquidity, slippage, slippage, ZERO_BYTES);
        lpm.modifyLiquidities(calls, _deadline);
        BalanceDelta delta = getLastDelta();

        // confirm that delta == slippage tolerance
        assertEq(-delta.amount0(), int128(slippage));
        assertEq(-delta.amount1(), int128(slippage));
    }

    /// price movement from swaps will cause slippage reverts
    function test_increaseLiquidity_slippage_revert_swap() public {
        // increasing liquidity with perfect slippage parameters does not revert
        uint256 tokenId = lpm.nextTokenId();
        mint(config, 100e18, ActionConstants.MSG_SENDER, ZERO_BYTES);

        uint128 newLiquidity = 10e18;
        (uint256 amount0, uint256 amount1) = LiquidityAmounts.getAmountsForLiquidity(
            SQRT_PRICE_1_1,
            TickMath.getSqrtPriceAtTick(config.tickLower),
            TickMath.getSqrtPriceAtTick(config.tickUpper),
            newLiquidity
        );
        assertEq(amount0, amount1); // symmetric liquidity addition
        uint128 slippage = uint128(amount0) + 1;

        // swap to create slippage
        swap(key, true, -10e18, ZERO_BYTES);

        bytes memory calls = getIncreaseEncoded(tokenId, config, newLiquidity, slippage, slippage, ZERO_BYTES);
        vm.expectRevert(
            abi.encodeWithSelector(SlippageCheck.MaximumAmountExceeded.selector, slippage, 299996249439153403)
        );
        lpm.modifyLiquidities(calls, _deadline);
    }

    function test_mint_settleWithBalance_andSweepToOtherAddress() public {
        uint256 liquidityAlice = 3_000e18;

        Plan memory planner = Planner.init();
        planner.add(
            Actions.MINT_POSITION,
            abi.encode(
                config.poolKey,
                config.tickLower,
                config.tickUpper,
                liquidityAlice,
                MAX_SLIPPAGE_INCREASE,
                MAX_SLIPPAGE_INCREASE,
                alice,
                ZERO_BYTES
            )
        );
        planner.add(Actions.SETTLE, abi.encode(currency0, ActionConstants.OPEN_DELTA, false));
        planner.add(Actions.SETTLE, abi.encode(currency1, ActionConstants.OPEN_DELTA, false));
        // this test sweeps to the test contract, even though Alice is the caller of the transaction
        planner.add(Actions.SWEEP, abi.encode(currency0, address(this)));
        planner.add(Actions.SWEEP, abi.encode(currency1, address(this)));

        uint256 balanceBefore0 = currency0.balanceOf(address(this));
        uint256 balanceBefore1 = currency1.balanceOf(address(this));

        assertEq(currency0.balanceOf(address(lpm)), 0);
        assertEq(currency0.balanceOf(address(lpm)), 0);

        currency0.transfer(address(lpm), 100e18);
        currency1.transfer(address(lpm), 100e18);

        assertEq(currency0.balanceOf(address(lpm)), 100e18);
        assertEq(currency0.balanceOf(address(lpm)), 100e18);

        bytes memory calls = planner.encode();

        vm.prank(alice);
        lpm.modifyLiquidities(calls, _deadline);
        BalanceDelta delta = getLastDelta();
        uint256 amount0 = uint128(-delta.amount0());
        uint256 amount1 = uint128(-delta.amount1());

        // The balances were swept back to this address.
        assertEq(IERC20(Currency.unwrap(currency0)).balanceOf(address(lpm)), 0);
        assertEq(IERC20(Currency.unwrap(currency1)).balanceOf(address(lpm)), 0);

        assertEq(currency0.balanceOf(address(this)), balanceBefore0 - amount0);
        assertEq(currency1.balanceOf(address(this)), balanceBefore1 - amount1);
    }

    function test_mint_settleWithBalance_andSweepToMsgSender() public {
        uint256 liquidityAlice = 3_000e18;

        Plan memory planner = Planner.init();
        planner.add(
            Actions.MINT_POSITION,
            abi.encode(
                config.poolKey,
                config.tickLower,
                config.tickUpper,
                liquidityAlice,
                MAX_SLIPPAGE_INCREASE,
                MAX_SLIPPAGE_INCREASE,
                alice,
                ZERO_BYTES
            )
        );
        planner.add(Actions.SETTLE, abi.encode(currency0, ActionConstants.OPEN_DELTA, false));
        planner.add(Actions.SETTLE, abi.encode(currency1, ActionConstants.OPEN_DELTA, false));
        planner.add(Actions.SWEEP, abi.encode(currency0, ActionConstants.MSG_SENDER));
        planner.add(Actions.SWEEP, abi.encode(currency1, ActionConstants.MSG_SENDER));

        uint256 balanceBefore0 = currency0.balanceOf(alice);
        uint256 balanceBefore1 = currency1.balanceOf(alice);

        uint256 seedAmount = 100e18;
        currency0.transfer(address(lpm), seedAmount);
        currency1.transfer(address(lpm), seedAmount);

        assertEq(currency0.balanceOf(address(lpm)), seedAmount);
        assertEq(currency0.balanceOf(address(lpm)), seedAmount);

        bytes memory calls = planner.encode();

        vm.prank(alice);
        lpm.modifyLiquidities(calls, _deadline);
        BalanceDelta delta = getLastDelta();
        uint256 amount0 = uint128(-delta.amount0());
        uint256 amount1 = uint128(-delta.amount1());

        // alice's balance has increased by the seeded funds that werent used to pay for the mint
        assertEq(currency0.balanceOf(alice), balanceBefore0 + (seedAmount - amount0));
        assertEq(currency1.balanceOf(alice), balanceBefore1 + (seedAmount - amount1));
    }

    function test_increaseLiquidity_settleWithBalance() public {
        uint256 liquidityAlice = 3_000e18;

        // alice provides liquidity
        vm.prank(alice);
        mint(config, liquidityAlice, alice, ZERO_BYTES);
        uint256 tokenIdAlice = lpm.nextTokenId() - 1;

        uint256 liquidity = lpm.getPositionLiquidity(tokenIdAlice);
        assertEq(liquidity, liquidityAlice);

        // alice increases with the balance in the position manager
        Plan memory planner = Planner.init();
        planner.add(
            Actions.INCREASE_LIQUIDITY,
            abi.encode(tokenIdAlice, liquidityAlice, MAX_SLIPPAGE_INCREASE, MAX_SLIPPAGE_INCREASE, ZERO_BYTES)
        );
        planner.add(Actions.SETTLE, abi.encode(currency0, ActionConstants.OPEN_DELTA, false));
        planner.add(Actions.SETTLE, abi.encode(currency1, ActionConstants.OPEN_DELTA, false));
        // this test sweeps to the test contract, even though Alice is the caller of the transaction
        planner.add(Actions.SWEEP, abi.encode(currency0, address(this)));
        planner.add(Actions.SWEEP, abi.encode(currency1, address(this)));

        uint256 balanceBefore0 = currency0.balanceOf(address(this));
        uint256 balanceBefore1 = currency1.balanceOf(address(this));

        assertEq(currency0.balanceOf(address(lpm)), 0);
        assertEq(currency0.balanceOf(address(lpm)), 0);

        currency0.transfer(address(lpm), 100e18);
        currency1.transfer(address(lpm), 100e18);

        assertEq(currency0.balanceOf(address(lpm)), 100e18);
        assertEq(currency0.balanceOf(address(lpm)), 100e18);

        bytes memory calls = planner.encode();

        vm.prank(alice);
        lpm.modifyLiquidities(calls, _deadline);
        BalanceDelta delta = getLastDelta();
        uint256 amount0 = uint128(-delta.amount0());
        uint256 amount1 = uint128(-delta.amount1());

        liquidity = lpm.getPositionLiquidity(tokenIdAlice);
        assertEq(liquidity, 2 * liquidityAlice);

        // The balances were swept back to this address.
        assertEq(IERC20(Currency.unwrap(currency0)).balanceOf(address(lpm)), 0);
        assertEq(IERC20(Currency.unwrap(currency1)).balanceOf(address(lpm)), 0);

        assertEq(currency0.balanceOf(address(this)), balanceBefore0 - amount0);
        assertEq(currency1.balanceOf(address(this)), balanceBefore1 - amount1);
    }

    /// @dev if clearing exceeds the max amount, the amount is taken instead
    function test_increaseLiquidity_clearExceedsThenTake() public {
        uint256 tokenId = lpm.nextTokenId();
        mint(config, 1000e18, address(this), ZERO_BYTES);

        // donate to create fee revenue
        uint256 amountToDonate = 0.2e18;
        donateRouter.donate(key, amountToDonate, amountToDonate, ZERO_BYTES);

        // calculate the amount of liquidity to add, using half of the proceeds
        uint256 amountToReinvest = amountToDonate / 2;
        uint256 amountToReclaim = amountToDonate / 2; // expect to reclaim the other half of the fee revenue
        uint256 liquidityDelta = LiquidityAmounts.getLiquidityForAmounts(
            SQRT_PRICE_1_1,
            TickMath.getSqrtPriceAtTick(config.tickLower),
            TickMath.getSqrtPriceAtTick(config.tickUpper),
            amountToReinvest,
            amountToReinvest
        );

        // set the max-forfeit to less than the amount we expect to claim
        uint256 maxClear = amountToReclaim - 2 wei;

        Plan memory planner = Planner.init();
        planner.add(
            Actions.INCREASE_LIQUIDITY,
            abi.encode(tokenId, liquidityDelta, MAX_SLIPPAGE_INCREASE, MAX_SLIPPAGE_INCREASE, ZERO_BYTES)
        );
        planner.add(Actions.CLEAR_OR_TAKE, abi.encode(config.poolKey.currency0, maxClear));
        planner.add(Actions.CLEAR_OR_TAKE, abi.encode(config.poolKey.currency1, maxClear));
        bytes memory calls = planner.encode();

        uint256 balance0Before = currency0.balanceOf(address(this));
        uint256 balance1Before = currency1.balanceOf(address(this));

        // expect to take the excess, as it exceeds the amount to clear
        lpm.modifyLiquidities(calls, _deadline);
        BalanceDelta delta = getLastDelta();

        assertEq(uint128(delta.amount0()), amountToReclaim - 1 wei); // imprecision
        assertEq(uint128(delta.amount1()), amountToReclaim - 1 wei);

        assertEq(currency0.balanceOf(address(this)), balance0Before + amountToReclaim - 1 wei);
        assertEq(currency1.balanceOf(address(this)), balance1Before + amountToReclaim - 1 wei);
    }

    /// @dev clearing a negative delta reverts
    function test_increaseLiquidity_clearNegative_revert() public {
        uint256 tokenId = lpm.nextTokenId();
        mint(config, 1000e18, address(this), ZERO_BYTES);

        // increase liquidity with new tokens but try clearing the negative delta
        Plan memory planner = Planner.init();
        planner.add(
            Actions.INCREASE_LIQUIDITY,
            abi.encode(tokenId, 100e18, MAX_SLIPPAGE_INCREASE, MAX_SLIPPAGE_INCREASE, ZERO_BYTES)
        );
        planner.add(Actions.CLEAR_OR_TAKE, abi.encode(config.poolKey.currency0, type(uint256).max));
        planner.add(Actions.CLEAR_OR_TAKE, abi.encode(config.poolKey.currency1, type(uint256).max));
        bytes memory calls = planner.encode();

        // revert since we're trying to clear a negative delta
        vm.expectRevert(abi.encodeWithSelector(DeltaResolver.DeltaNotPositive.selector, currency0));
        lpm.modifyLiquidities(calls, _deadline);
    }
}
