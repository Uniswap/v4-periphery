// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {GasSnapshot} from "forge-gas-snapshot/GasSnapshot.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {LiquidityAmounts} from "../../contracts/libraries/LiquidityAmounts.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {Fuzzers} from "@uniswap/v4-core/src/test/Fuzzers.sol";

import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";

import {NonfungiblePositionManager} from "../../contracts/NonfungiblePositionManager.sol";
import {LiquidityRange, LiquidityRangeId, LiquidityRangeIdLibrary} from "../../contracts/types/LiquidityRange.sol";
import {Actions, INonfungiblePositionManager} from "../../contracts/interfaces/INonfungiblePositionManager.sol";
import {LiquidityOperations} from "../shared/LiquidityOperations.sol";
import {Planner} from "../utils/Planner.sol";
import {FeeMath} from "../shared/FeeMath.sol";

contract IncreaseLiquidityTest is Test, Deployers, GasSnapshot, Fuzzers, LiquidityOperations {
    using FixedPointMathLib for uint256;
    using CurrencyLibrary for Currency;
    using LiquidityRangeIdLibrary for LiquidityRange;
    using PoolIdLibrary for PoolKey;
    using Planner for Planner.Plan;
    using FeeMath for INonfungiblePositionManager;

    PoolId poolId;
    address alice = makeAddr("ALICE");
    address bob = makeAddr("BOB");

    uint256 constant STARTING_USER_BALANCE = 10_000_000 ether;

    // expresses the fee as a wad (i.e. 3000 = 0.003e18 = 0.30%)
    uint256 FEE_WAD;

    LiquidityRange range;

    function setUp() public {
        Deployers.deployFreshManagerAndRouters();
        Deployers.deployMintAndApprove2Currencies();

        (key, poolId) = initPool(currency0, currency1, IHooks(address(0)), 3000, SQRT_PRICE_1_1, ZERO_BYTES);
        FEE_WAD = uint256(key.fee).mulDivDown(FixedPointMathLib.WAD, 1_000_000);

        lpm = new NonfungiblePositionManager(manager);
        IERC20(Currency.unwrap(currency0)).approve(address(lpm), type(uint256).max);
        IERC20(Currency.unwrap(currency1)).approve(address(lpm), type(uint256).max);

        // Give tokens to Alice and Bob, with approvals
        IERC20(Currency.unwrap(currency0)).transfer(alice, STARTING_USER_BALANCE);
        IERC20(Currency.unwrap(currency1)).transfer(alice, STARTING_USER_BALANCE);
        IERC20(Currency.unwrap(currency0)).transfer(bob, STARTING_USER_BALANCE);
        IERC20(Currency.unwrap(currency1)).transfer(bob, STARTING_USER_BALANCE);
        vm.startPrank(alice);
        IERC20(Currency.unwrap(currency0)).approve(address(lpm), type(uint256).max);
        IERC20(Currency.unwrap(currency1)).approve(address(lpm), type(uint256).max);
        vm.stopPrank();
        vm.startPrank(bob);
        IERC20(Currency.unwrap(currency0)).approve(address(lpm), type(uint256).max);
        IERC20(Currency.unwrap(currency1)).approve(address(lpm), type(uint256).max);
        vm.stopPrank();

        // define a reusable range
        range = LiquidityRange({poolKey: key, tickLower: -300, tickUpper: 300});
    }

    function test_increaseLiquidity_withExactFees() public {
        // Alice and Bob provide liquidity on the range
        // Alice uses her exact fees to increase liquidity (compounding)

        uint256 liquidityAlice = 3_000e18;
        uint256 liquidityBob = 1_000e18;

        // alice provides liquidity
        vm.prank(alice);
        _mint(range, liquidityAlice, block.timestamp + 1, alice, ZERO_BYTES);
        uint256 tokenIdAlice = lpm.nextTokenId() - 1;

        // bob provides liquidity
        vm.prank(bob);
        _mint(range, liquidityBob, block.timestamp + 1, bob, ZERO_BYTES);

        // swap to create fees
        uint256 swapAmount = 0.001e18;
        swap(key, true, -int256(swapAmount), ZERO_BYTES);
        swap(key, false, -int256(swapAmount), ZERO_BYTES); // move the price back

        // alice uses her exact fees to increase liquidity
        // Slight error in this calculation vs. actual fees.. TODO: Fix this.
        BalanceDelta feesOwedAlice = INonfungiblePositionManager(lpm).getFeesOwed(manager, tokenIdAlice);
        // Note: You can alternatively calculate Alice's fees owed from the swap amount, fee on the pool, and total liquidity in that range.
        // swapAmount.mulWadDown(FEE_WAD).mulDivDown(liquidityAlice, liquidityAlice + liquidityBob);

        (uint160 sqrtPriceX96,,,) = StateLibrary.getSlot0(manager, range.poolKey.toId());
        uint256 liquidityDelta = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(range.tickLower),
            TickMath.getSqrtPriceAtTick(range.tickUpper),
            uint256(int256(feesOwedAlice.amount0())),
            uint256(int256(feesOwedAlice.amount1()))
        );

        uint256 balance0BeforeAlice = currency0.balanceOf(alice);
        uint256 balance1BeforeAlice = currency1.balanceOf(alice);

        // TODO: Can we make this easier to re-invest fees, so that you don't need to know the exact collect amount?
        Planner.Plan memory planner = Planner.init();
        planner = planner.add(Actions.INCREASE, abi.encode(tokenIdAlice, liquidityDelta, ZERO_BYTES));
        planner = planner.finalize(range.poolKey);
        vm.startPrank(alice);
        lpm.modifyLiquidities(planner.zip());
        vm.stopPrank();

        // It is not exact because of the error in the fee calculation and error in the
        uint256 tolerance = 0.00000000001 ether;

        // alice barely spent any tokens
        // TODO: This is a case for not caring about dust left in pool manager :/
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
        _mint(range, liquidityAlice, block.timestamp + 1, alice, ZERO_BYTES);
        uint256 tokenIdAlice = lpm.nextTokenId() - 1;

        // bob provides liquidity
        vm.prank(bob);
        _mint(range, liquidityBob, block.timestamp + 1, bob, ZERO_BYTES);

        // donate to create fees
        uint256 amountDonate = 0.2e18;
        donateRouter.donate(key, 0.2e18, 0.2e18, ZERO_BYTES);

        // subtract 1 cause we'd rather take than pay
        uint256 feesAmount = amountDonate.mulDivDown(liquidityAlice, liquidityAlice + liquidityBob) - 1;

        (uint160 sqrtPriceX96,,,) = StateLibrary.getSlot0(manager, range.poolKey.toId());
        uint256 liquidityDelta = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(range.tickLower),
            TickMath.getSqrtPriceAtTick(range.tickUpper),
            feesAmount,
            feesAmount
        );

        uint256 balance0BeforeAlice = currency0.balanceOf(alice);
        uint256 balance1BeforeAlice = currency1.balanceOf(alice);

        vm.startPrank(alice);
        _increaseLiquidity(tokenIdAlice, liquidityDelta, ZERO_BYTES);
        vm.stopPrank();

        // It is not exact because of the error in the fee calculation and error in the
        uint256 tolerance = 0.00000000001 ether;

        // alice barely spent any tokens
        // TODO: This is a case for not caring about dust left in pool manager :/
        assertApproxEqAbs(balance0BeforeAlice, currency0.balanceOf(alice), tolerance);
        assertApproxEqAbs(balance1BeforeAlice, currency1.balanceOf(alice), tolerance);
    }

    // function test_increaseLiquidity_withExcessFees() public {
    //     // Alice and Bob provide liquidity on the range
    //     // Alice uses her fees to increase liquidity. Excess fees are accounted to alice
    //     uint256 liquidityAlice = 3_000e18;
    //     uint256 liquidityBob = 1_000e18;
    //     uint256 totalLiquidity = liquidityAlice + liquidityBob;

    //     // alice provides liquidity
    //     vm.prank(alice);
    //     _mint(range, liquidityAlice, block.timestamp + 1, alice, ZERO_BYTES);
    //     uint256 tokenIdAlice = lpm.nextTokenId() - 1;

    //     // bob provides liquidity
    //     vm.prank(bob);
    //     _mint(range, liquidityBob, block.timestamp + 1, bob, ZERO_BYTES);
    //     uint256 tokenIdBob = lpm.nextTokenId() - 1;

    //     // swap to create fees
    //     uint256 swapAmount = 0.001e18;
    //     swap(key, true, -int256(swapAmount), ZERO_BYTES);
    //     swap(key, false, -int256(swapAmount), ZERO_BYTES); // move the price back

    //     // alice will use half of her fees to increase liquidity
    //     (uint256 token0Owed, uint256 token1Owed) = lpm.feesOwed(tokenIdAlice);
    //     {
    //         (uint160 sqrtPriceX96,,,) = StateLibrary.getSlot0(manager, range.poolKey.toId());
    //         uint256 liquidityDelta = LiquidityAmounts.getLiquidityForAmounts(
    //             sqrtPriceX96,
    //             TickMath.getSqrtPriceAtTick(range.tickLower),
    //             TickMath.getSqrtPriceAtTick(range.tickUpper),
    //             token0Owed / 2,
    //             token1Owed / 2
    //         );

    //         vm.startPrank(alice);
    //         _increaseLiquidity(tokenIdAlice, liquidityDelta, ZERO_BYTES, false);
    //         vm.stopPrank();
    //     }

    //     {
    //         // bob collects his fees
    //         uint256 balance0BeforeBob = currency0.balanceOf(bob);
    //         uint256 balance1BeforeBob = currency1.balanceOf(bob);
    //         vm.startPrank(bob);
    //         _collect(tokenIdBob, bob, ZERO_BYTES, false);
    //         vm.stopPrank();
    //         uint256 balance0AfterBob = currency0.balanceOf(bob);
    //         uint256 balance1AfterBob = currency1.balanceOf(bob);
    //         assertApproxEqAbs(
    //             balance0AfterBob - balance0BeforeBob,
    //             swapAmount.mulWadDown(FEE_WAD).mulDivDown(liquidityBob, totalLiquidity),
    //             1 wei
    //         );
    //         assertApproxEqAbs(
    //             balance1AfterBob - balance1BeforeBob,
    //             swapAmount.mulWadDown(FEE_WAD).mulDivDown(liquidityBob, totalLiquidity),
    //             1 wei
    //         );
    //     }

    //     {
    //         // alice collects her fees, which should be about half of the fees
    //         uint256 balance0BeforeAlice = currency0.balanceOf(alice);
    //         uint256 balance1BeforeAlice = currency1.balanceOf(alice);
    //         vm.startPrank(alice);
    //         _collect(tokenIdAlice, alice, ZERO_BYTES, false);
    //         vm.stopPrank();
    //         uint256 balance0AfterAlice = currency0.balanceOf(alice);
    //         uint256 balance1AfterAlice = currency1.balanceOf(alice);
    //         assertApproxEqAbs(
    //             balance0AfterAlice - balance0BeforeAlice,
    //             swapAmount.mulWadDown(FEE_WAD).mulDivDown(liquidityAlice, totalLiquidity) / 2,
    //             9 wei
    //         );
    //         assertApproxEqAbs(
    //             balance1AfterAlice - balance1BeforeAlice,
    //             swapAmount.mulWadDown(FEE_WAD).mulDivDown(liquidityAlice, totalLiquidity) / 2,
    //             1 wei
    //         );
    //     }
    // }

    function test_increaseLiquidity_withInsufficientFees() public {
        // Alice and Bob provide liquidity on the range
        // Alice uses her fees to increase liquidity. Additional funds are used by alice to increase liquidity
        uint256 liquidityAlice = 3_000e18;
        uint256 liquidityBob = 1_000e18;
        uint256 totalLiquidity = liquidityAlice + liquidityBob;

        // alice provides liquidity
        vm.prank(alice);
        _mint(range, liquidityAlice, block.timestamp + 1, alice, ZERO_BYTES);
        uint256 tokenIdAlice = lpm.nextTokenId() - 1;

        // bob provides liquidity
        vm.prank(bob);
        _mint(range, liquidityBob, block.timestamp + 1, bob, ZERO_BYTES);
        uint256 tokenIdBob = lpm.nextTokenId() - 1;

        // swap to create fees
        uint256 swapAmount = 0.001e18;
        swap(key, true, -int256(swapAmount), ZERO_BYTES);
        swap(key, false, -int256(swapAmount), ZERO_BYTES); // move the price back

        // alice will use all of her fees + additional capital to increase liquidity
        BalanceDelta feesOwed = INonfungiblePositionManager(lpm).getFeesOwed(manager, tokenIdAlice);

        {
            (uint160 sqrtPriceX96,,,) = StateLibrary.getSlot0(manager, range.poolKey.toId());
            uint256 liquidityDelta = LiquidityAmounts.getLiquidityForAmounts(
                sqrtPriceX96,
                TickMath.getSqrtPriceAtTick(range.tickLower),
                TickMath.getSqrtPriceAtTick(range.tickUpper),
                uint256(int256(feesOwed.amount0())) * 2,
                uint256(int256(feesOwed.amount1())) * 2
            );

            uint256 balance0BeforeAlice = currency0.balanceOf(alice);
            uint256 balance1BeforeAlice = currency1.balanceOf(alice);
            vm.startPrank(alice);
            _increaseLiquidity(tokenIdAlice, liquidityDelta, ZERO_BYTES);
            vm.stopPrank();
            uint256 balance0AfterAlice = currency0.balanceOf(alice);
            uint256 balance1AfterAlice = currency1.balanceOf(alice);

            // Alice owed feesOwed amount in 0 and 1 because she places feesOwed * 2 back into the pool.
            assertApproxEqAbs(balance0BeforeAlice - balance0AfterAlice, uint256(int256(feesOwed.amount0())), 37 wei);
            assertApproxEqAbs(balance1BeforeAlice - balance1AfterAlice, uint256(int256(feesOwed.amount1())), 1 wei);
        }

        {
            // bob collects his fees
            uint256 balance0BeforeBob = currency0.balanceOf(bob);
            uint256 balance1BeforeBob = currency1.balanceOf(bob);
            vm.startPrank(bob);
            _collect(tokenIdBob, bob, ZERO_BYTES);
            vm.stopPrank();
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
}
