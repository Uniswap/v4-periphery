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

import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";

import {NonfungiblePositionManager} from "../../contracts/NonfungiblePositionManager.sol";
import {LiquidityRange, LiquidityRangeId, LiquidityRangeIdLibrary} from "../../contracts/types/LiquidityRange.sol";

import {Fuzzers} from "@uniswap/v4-core/src/test/Fuzzers.sol";

import {LiquidityOperations} from "../shared/LiquidityOperations.sol";

import "forge-std/console2.sol";

contract IncreaseLiquidityTest is Test, Deployers, GasSnapshot, Fuzzers, LiquidityOperations {
    using FixedPointMathLib for uint256;
    using CurrencyLibrary for Currency;
    using LiquidityRangeIdLibrary for LiquidityRange;
    using PoolIdLibrary for PoolKey;

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
        (uint256 token0Owed, uint256 token1Owed) = lpm.feesOwed(tokenIdAlice);

        (uint160 sqrtPriceX96,,,) = StateLibrary.getSlot0(manager, range.poolKey.toId());
        uint256 liquidityDelta = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(range.tickLower),
            TickMath.getSqrtPriceAtTick(range.tickUpper),
            token0Owed,
            token1Owed
        );

        uint256 balance0BeforeAlice = currency0.balanceOf(alice);
        uint256 balance1BeforeAlice = currency1.balanceOf(alice);

        vm.startPrank(alice);
        _increaseLiquidity(tokenIdAlice, liquidityDelta, ZERO_BYTES, false);
        vm.stopPrank();

        // alice did not spend any tokens
        assertEq(balance0BeforeAlice, currency0.balanceOf(alice));
        assertEq(balance1BeforeAlice, currency1.balanceOf(alice));

        // alice spent all of the fees, approximately
        (token0Owed, token1Owed) = lpm.feesOwed(tokenIdAlice);
        assertApproxEqAbs(token0Owed, 0, 20 wei);
        assertApproxEqAbs(token1Owed, 0, 20 wei);
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
        donateRouter.donate(key, 0.2e18, 0.2e18, ZERO_BYTES);

        // alice uses her exact fees to increase liquidity
        (uint256 token0Owed, uint256 token1Owed) = lpm.feesOwed(tokenIdAlice);

        (uint160 sqrtPriceX96,,,) = StateLibrary.getSlot0(manager, range.poolKey.toId());
        uint256 liquidityDelta = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(range.tickLower),
            TickMath.getSqrtPriceAtTick(range.tickUpper),
            token0Owed,
            token1Owed
        );

        uint256 balance0BeforeAlice = currency0.balanceOf(alice);
        uint256 balance1BeforeAlice = currency1.balanceOf(alice);

        vm.startPrank(alice);
        _increaseLiquidity(tokenIdAlice, liquidityDelta, ZERO_BYTES, false);
        vm.stopPrank();

        // alice did not spend any tokens
        assertEq(balance0BeforeAlice, currency0.balanceOf(alice));
        assertEq(balance1BeforeAlice, currency1.balanceOf(alice));

        // alice spent all of the fees
        (token0Owed, token1Owed) = lpm.feesOwed(tokenIdAlice);
        assertEq(token0Owed, 0);
        assertEq(token1Owed, 0);
    }

    function test_increaseLiquidity_withExcessFees() public {
        // Alice and Bob provide liquidity on the range
        // Alice uses her fees to increase liquidity. Excess fees are accounted to alice
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

        // alice will use half of her fees to increase liquidity
        (uint256 token0Owed, uint256 token1Owed) = lpm.feesOwed(tokenIdAlice);
        {
            (uint160 sqrtPriceX96,,,) = StateLibrary.getSlot0(manager, range.poolKey.toId());
            uint256 liquidityDelta = LiquidityAmounts.getLiquidityForAmounts(
                sqrtPriceX96,
                TickMath.getSqrtPriceAtTick(range.tickLower),
                TickMath.getSqrtPriceAtTick(range.tickUpper),
                token0Owed / 2,
                token1Owed / 2
            );

            vm.startPrank(alice);
            _increaseLiquidity(tokenIdAlice, liquidityDelta, ZERO_BYTES, false);
            vm.stopPrank();
        }

        {
            // bob collects his fees
            uint256 balance0BeforeBob = currency0.balanceOf(bob);
            uint256 balance1BeforeBob = currency1.balanceOf(bob);
            vm.startPrank(bob);
            _collect(tokenIdBob, bob, ZERO_BYTES, false);
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

        {
            // alice collects her fees, which should be about half of the fees
            uint256 balance0BeforeAlice = currency0.balanceOf(alice);
            uint256 balance1BeforeAlice = currency1.balanceOf(alice);
            vm.startPrank(alice);
            _collect(tokenIdAlice, alice, ZERO_BYTES, false);
            vm.stopPrank();
            uint256 balance0AfterAlice = currency0.balanceOf(alice);
            uint256 balance1AfterAlice = currency1.balanceOf(alice);
            assertApproxEqAbs(
                balance0AfterAlice - balance0BeforeAlice,
                swapAmount.mulWadDown(FEE_WAD).mulDivDown(liquidityAlice, totalLiquidity) / 2,
                9 wei
            );
            assertApproxEqAbs(
                balance1AfterAlice - balance1BeforeAlice,
                swapAmount.mulWadDown(FEE_WAD).mulDivDown(liquidityAlice, totalLiquidity) / 2,
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
        (uint256 token0Owed, uint256 token1Owed) = lpm.feesOwed(tokenIdAlice);
        {
            (uint160 sqrtPriceX96,,,) = StateLibrary.getSlot0(manager, range.poolKey.toId());
            uint256 liquidityDelta = LiquidityAmounts.getLiquidityForAmounts(
                sqrtPriceX96,
                TickMath.getSqrtPriceAtTick(range.tickLower),
                TickMath.getSqrtPriceAtTick(range.tickUpper),
                token0Owed * 2,
                token1Owed * 2
            );

            uint256 balance0BeforeAlice = currency0.balanceOf(alice);
            uint256 balance1BeforeAlice = currency1.balanceOf(alice);
            vm.startPrank(alice);
            _increaseLiquidity(tokenIdAlice, liquidityDelta, ZERO_BYTES, false);
            vm.stopPrank();
            uint256 balance0AfterAlice = currency0.balanceOf(alice);
            uint256 balance1AfterAlice = currency1.balanceOf(alice);

            assertApproxEqAbs(balance0BeforeAlice - balance0AfterAlice, token0Owed, 37 wei);
            assertApproxEqAbs(balance1BeforeAlice - balance1AfterAlice, token1Owed, 1 wei);
        }

        {
            // bob collects his fees
            uint256 balance0BeforeBob = currency0.balanceOf(bob);
            uint256 balance1BeforeBob = currency1.balanceOf(bob);
            vm.startPrank(bob);
            _collect(tokenIdBob, bob, ZERO_BYTES, false);
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

    function test_increaseLiquidity_withExactFees_withExactCachedFees() public {
        // Alice and Bob provide liquidity on the range
        // Alice uses her fees to increase liquidity. Both unclaimed fees and cached fees are used to exactly increase the liquidity
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

        (uint256 token0Owed, uint256 token1Owed) = lpm.feesOwed(tokenIdAlice);

        // bob collects fees so some of alice's fees are now cached

        vm.startPrank(bob);
        _collect(tokenIdBob, bob, ZERO_BYTES, false);
        vm.stopPrank();
        // swap to create more fees
        swap(key, true, -int256(swapAmount), ZERO_BYTES);
        swap(key, false, -int256(swapAmount), ZERO_BYTES); // move the price back

        (uint256 newToken0Owed, uint256 newToken1Owed) = lpm.feesOwed(tokenIdAlice);
        // alice's fees should be doubled
        assertApproxEqAbs(newToken0Owed, token0Owed * 2, 2 wei);
        assertApproxEqAbs(newToken1Owed, token1Owed * 2, 2 wei);

        uint256 balance0AliceBefore = currency0.balanceOf(alice);
        uint256 balance1AliceBefore = currency1.balanceOf(alice);

        // alice will use ALL of her fees to increase liquidity
        {
            (uint160 sqrtPriceX96,,,) = StateLibrary.getSlot0(manager, range.poolKey.toId());
            uint256 liquidityDelta = LiquidityAmounts.getLiquidityForAmounts(
                sqrtPriceX96,
                TickMath.getSqrtPriceAtTick(range.tickLower),
                TickMath.getSqrtPriceAtTick(range.tickUpper),
                newToken0Owed,
                newToken1Owed
            );

            vm.startPrank(alice);
            _increaseLiquidity(tokenIdAlice, liquidityDelta, ZERO_BYTES, false);
            vm.stopPrank();
        }

        // alice did not spend any tokens
        assertEq(balance0AliceBefore, currency0.balanceOf(alice));
        assertEq(balance1AliceBefore, currency1.balanceOf(alice));

        // some dust was credited to alice's tokensOwed
        (token0Owed, token1Owed) = lpm.feesOwed(tokenIdAlice);
        assertApproxEqAbs(token0Owed, 0, 80 wei);
        assertApproxEqAbs(token1Owed, 0, 80 wei);
    }

    // uses donate to simulate fee revenue
    function test_increaseLiquidity_withExactFees_withExactCachedFees_donate() public {
        // Alice and Bob provide liquidity on the range
        // Alice uses her fees to increase liquidity. Both unclaimed fees and cached fees are used to exactly increase the liquidity
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

        // donate to create fees
        donateRouter.donate(key, 20e18, 20e18, ZERO_BYTES);

        (uint256 token0Owed, uint256 token1Owed) = lpm.feesOwed(tokenIdAlice);

        // bob collects fees so some of alice's fees are now cached
        vm.startPrank(bob);
        _collect(tokenIdBob, bob, ZERO_BYTES, false);
        vm.stopPrank();

        // donate to create more fees
        donateRouter.donate(key, 20e18, 20e18, ZERO_BYTES);

        (uint256 newToken0Owed, uint256 newToken1Owed) = lpm.feesOwed(tokenIdAlice);
        // alice's fees should be doubled
        assertApproxEqAbs(newToken0Owed, token0Owed * 2, 1 wei);
        assertApproxEqAbs(newToken1Owed, token1Owed * 2, 1 wei);

        uint256 balance0AliceBefore = currency0.balanceOf(alice);
        uint256 balance1AliceBefore = currency1.balanceOf(alice);

        // alice will use ALL of her fees to increase liquidity
        {
            (uint160 sqrtPriceX96,,,) = StateLibrary.getSlot0(manager, range.poolKey.toId());
            uint256 liquidityDelta = LiquidityAmounts.getLiquidityForAmounts(
                sqrtPriceX96,
                TickMath.getSqrtPriceAtTick(range.tickLower),
                TickMath.getSqrtPriceAtTick(range.tickUpper),
                newToken0Owed,
                newToken1Owed
            );

            vm.startPrank(alice);
            _increaseLiquidity(tokenIdAlice, liquidityDelta, ZERO_BYTES, false);
            vm.stopPrank();
        }

        // alice did not spend any tokens
        assertEq(balance0AliceBefore, currency0.balanceOf(alice), "alice spent token0");
        assertEq(balance1AliceBefore, currency1.balanceOf(alice), "alice spent token1");

        (token0Owed, token1Owed) = lpm.feesOwed(tokenIdAlice);
        assertEq(token0Owed, 0);
        assertEq(token1Owed, 0);

        // bob still collects 5
        (token0Owed, token1Owed) = lpm.feesOwed(tokenIdBob);
        assertApproxEqAbs(token0Owed, 5e18, 1 wei);
        assertApproxEqAbs(token1Owed, 5e18, 1 wei);

        vm.startPrank(bob);
        BalanceDelta result = _collect(tokenIdBob, bob, ZERO_BYTES, false);
        vm.stopPrank();
        assertApproxEqAbs(result.amount0(), 5e18, 1 wei);
        assertApproxEqAbs(result.amount1(), 5e18, 1 wei);
    }
}
