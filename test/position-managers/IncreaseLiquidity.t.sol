// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {FixedPointMathLib} from "solmate/src/utils/FixedPointMathLib.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {Fuzzers} from "@uniswap/v4-core/src/test/Fuzzers.sol";

import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {PositionManager} from "../../src/PositionManager.sol";
import {PositionConfig} from "../../src/libraries/PositionConfig.sol";
import {Actions, IPositionManager} from "../../src/interfaces/IPositionManager.sol";
import {Planner} from "../shared/Planner.sol";
import {FeeMath} from "../shared/FeeMath.sol";
import {PosmTestSetup} from "../shared/PosmTestSetup.sol";

contract IncreaseLiquidityTest is Test, PosmTestSetup, Fuzzers {
    using FixedPointMathLib for uint256;
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;
    using Planner for Planner.Plan;
    using FeeMath for IPositionManager;

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

        (key, poolId) = initPool(currency0, currency1, IHooks(address(0)), 3000, SQRT_PRICE_1_1, ZERO_BYTES);
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

    function test_increaseLiquidity_withExactFees() public {
        // Alice and Bob provide liquidity on the range
        // Alice uses her exact fees to increase liquidity (compounding)

        uint256 liquidityAlice = 3_000e18;
        uint256 liquidityBob = 1_000e18;

        // alice provides liquidity
        vm.prank(alice);
        mint(config, liquidityAlice, alice, ZERO_BYTES);
        uint256 tokenIdAlice = lpm.nextTokenId() - 1;

        // bob provides liquidity
        vm.prank(bob);
        mint(config, liquidityBob, bob, ZERO_BYTES);

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

        // TODO: Can we make this easier to re-invest fees, so that you don't need to know the exact collect amount?
        Planner.Plan memory planner = Planner.init();
        planner = planner.add(Actions.INCREASE, abi.encode(tokenIdAlice, config, liquidityDelta, ZERO_BYTES));
        bytes memory calls = planner.finalize(config.poolKey);
        vm.startPrank(alice);
        lpm.modifyLiquidities(calls, _deadline);
        vm.stopPrank();

        // alice barely spent any tokens
        // TODO: Use clear.
        assertApproxEqAbs(balance0BeforeAlice, currency0.balanceOf(alice), tolerance);
        assertApproxEqAbs(balance1BeforeAlice, currency1.balanceOf(alice), tolerance);
    }

    // uses donate to simulate fee revenue
    function test_increaseLiquidity_withExactFees_donate() public {
        // Alice and Bob provide liquidity on the range
        // Alice uses her exact fees to increase liquidity (compounding)

        uint256 liquidityAlice = 3_000e18;
        uint256 liquidityBob = 1_000e18;

        // alice provides liquidity
        vm.prank(alice);
        mint(config, liquidityAlice, alice, ZERO_BYTES);
        uint256 tokenIdAlice = lpm.nextTokenId() - 1;

        // bob provides liquidity
        vm.prank(bob);
        mint(config, liquidityBob, bob, ZERO_BYTES);

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
        // TODO: Use clear.
        assertApproxEqAbs(balance0BeforeAlice, currency0.balanceOf(alice), tolerance);
        assertApproxEqAbs(balance1BeforeAlice, currency1.balanceOf(alice), tolerance);
    }

    function test_increaseLiquidity_withUnapprovedCaller() public {
        // Alice provides liquidity
        // Bob increases Alice's liquidity without being approved
        uint256 liquidityAlice = 3_000e18;

        // alice provides liquidity
        vm.prank(alice);
        mint(config, liquidityAlice, alice, ZERO_BYTES);
        uint256 tokenIdAlice = lpm.nextTokenId() - 1;

        bytes32 positionId =
            keccak256(abi.encodePacked(address(lpm), config.tickLower, config.tickUpper, bytes32(tokenIdAlice)));
        uint128 oldLiquidity = StateLibrary.getPositionLiquidity(manager, config.poolKey.toId(), positionId);

        // bob can increase liquidity for alice even though he is not the owner / not approved
        vm.startPrank(bob);
        increaseLiquidity(tokenIdAlice, config, 100e18, ZERO_BYTES);
        vm.stopPrank();

        uint128 newLiquidity = StateLibrary.getPositionLiquidity(manager, config.poolKey.toId(), positionId);

        // assert liqudity increased by the correct amount
        assertEq(newLiquidity, oldLiquidity + uint128(100e18));
    }

    function test_increaseLiquidity_sameRange_withExcessFees() public {
        // Alice and Bob provide liquidity on the same range
        // Alice uses half her fees to increase liquidity. The other half are collected to her wallet.
        // Bob collects all fees.
        uint256 liquidityAlice = 3_000e18;
        uint256 liquidityBob = 1_000e18;
        uint256 totalLiquidity = liquidityAlice + liquidityBob;

        // alice provides liquidity
        vm.prank(alice);
        mint(config, liquidityAlice, alice, ZERO_BYTES);
        uint256 tokenIdAlice = lpm.nextTokenId() - 1;

        // bob provides liquidity
        vm.prank(bob);
        mint(config, liquidityBob, bob, ZERO_BYTES);
        uint256 tokenIdBob = lpm.nextTokenId() - 1;

        // swap to create fees
        uint256 swapAmount = 0.001e18;
        swap(key, true, -int256(swapAmount), ZERO_BYTES);
        swap(key, false, -int256(swapAmount), ZERO_BYTES); // move the price back

        // alice will use half of her fees to increase liquidity
        BalanceDelta aliceFeesOwed = IPositionManager(lpm).getFeesOwed(manager, config, tokenIdAlice);

        {
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
        }
    }

    function test_increaseLiquidity_withInsufficientFees() public {
        // Alice and Bob provide liquidity on the range
        // Alice uses her fees to increase liquidity. Additional funds are used by alice to increase liquidity
        uint256 liquidityAlice = 3_000e18;
        uint256 liquidityBob = 1_000e18;
        uint256 totalLiquidity = liquidityAlice + liquidityBob;

        // alice provides liquidity
        vm.prank(alice);
        mint(config, liquidityAlice, alice, ZERO_BYTES);
        uint256 tokenIdAlice = lpm.nextTokenId() - 1;

        // bob provides liquidity
        vm.prank(bob);
        mint(config, liquidityBob, bob, ZERO_BYTES);
        uint256 tokenIdBob = lpm.nextTokenId() - 1;

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
}
