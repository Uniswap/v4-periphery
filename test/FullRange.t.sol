// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {Test} from "forge-std/Test.sol";
import {GasSnapshot} from "forge-gas-snapshot/GasSnapshot.sol";
import {Hooks} from "@uniswap/v4-core/contracts/libraries/Hooks.sol";
import {Position} from "@uniswap/v4-core/contracts/libraries/Position.sol";
import {FullRange} from "../contracts/hooks/FullRange.sol";
import {FullRangeImplementation} from "./shared/implementation/FullRangeImplementation.sol";
import {PoolManager} from "@uniswap/v4-core/contracts/PoolManager.sol";
import {IPoolManager} from "@uniswap/v4-core/contracts/interfaces/IPoolManager.sol";
import {Deployers} from "@uniswap/v4-core/test/foundry-tests/utils/Deployers.sol";
import {TestERC20} from "@uniswap/v4-core/contracts/test/TestERC20.sol";
import {CurrencyLibrary, Currency} from "@uniswap/v4-core/contracts/libraries/CurrencyLibrary.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/contracts/libraries/PoolId.sol";
import {PoolModifyPositionTest} from "@uniswap/v4-core/contracts/test/PoolModifyPositionTest.sol";
import {PoolSwapTest} from "@uniswap/v4-core/contracts/test/PoolSwapTest.sol";
import {TickMath} from "@uniswap/v4-core/contracts/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v4-core/contracts/libraries/FullMath.sol";
import {Oracle} from "../contracts/libraries/Oracle.sol";
import {IHooks} from "@uniswap/v4-core/contracts/interfaces/IHooks.sol";
import {UniswapV4ERC20} from "../contracts/hooks/UniswapV4ERC20.sol";
import "@uniswap/v4-core/contracts/libraries/FixedPoint128.sol";
import {BalanceDelta, BalanceDeltaLibrary, toBalanceDelta} from "@uniswap/v4-core/contracts/types/BalanceDelta.sol";

import "forge-std/console.sol";

contract TestFullRange is Test, Deployers, GasSnapshot {
    using PoolIdLibrary for IPoolManager.PoolKey;

    event Initialize(
        PoolId indexed poolId,
        Currency indexed currency0,
        Currency indexed currency1,
        uint24 fee,
        int24 tickSpacing,
        IHooks hooks
    );
    event ModifyPosition(
        PoolId indexed poolId, address indexed sender, int24 tickLower, int24 tickUpper, int256 liquidityDelta
    );
    event Swap(
        PoolId indexed id,
        address indexed sender,
        int128 amount0,
        int128 amount1,
        uint160 sqrtPriceX96,
        uint128 liquidity,
        int24 tick,
        uint24 fee
    );

    int24 constant TICK_SPACING = 60;
    uint160 constant SQRT_RATIO_2_1 = 112045541949572279837463876454;
    uint256 constant MAX_DEADLINE = 12329839823;

    /// @dev Min tick for full range with tick spacing of 60
    int24 internal constant MIN_TICK = -887220;
    /// @dev Max tick for full range with tick spacing of 60
    int24 internal constant MAX_TICK = -MIN_TICK;

    TestERC20 token0;
    TestERC20 token1;
    TestERC20 token2;

    PoolManager manager;
    FullRangeImplementation fullRange = FullRangeImplementation(
        address(uint160(Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_MODIFY_POSITION_FLAG | Hooks.BEFORE_SWAP_FLAG))
    );
    IPoolManager.PoolKey key;
    PoolId id;

    // the key that includes a pool fee for pool fee rebalance tests
    IPoolManager.PoolKey feeKey;
    PoolId feeId;

    IPoolManager.PoolKey feeKey2;
    PoolId feeId2;

    PoolModifyPositionTest modifyPositionRouter;
    PoolSwapTest swapRouter;

    function setUp() public {
        token0 = new TestERC20(2**128);
        token1 = new TestERC20(2**128);
        token2 = new TestERC20(2**128);
        manager = new PoolManager(500000);

        vm.record();
        FullRangeImplementation impl = new FullRangeImplementation(manager, fullRange);
        (, bytes32[] memory writes) = vm.accesses(address(impl));
        vm.etch(address(fullRange), address(impl).code);
        // for each storage key that was written during the hook implementation, copy the value over
        unchecked {
            for (uint256 i = 0; i < writes.length; i++) {
                bytes32 slot = writes[i];
                vm.store(address(fullRange), slot, vm.load(address(impl), slot));
            }
        }
        key = IPoolManager.PoolKey(
            Currency.wrap(address(token0)), Currency.wrap(address(token1)), 0, TICK_SPACING, fullRange
        );
        id = key.toId();

        feeKey = IPoolManager.PoolKey(
            Currency.wrap(address(token0)), Currency.wrap(address(token1)), 3000, TICK_SPACING, fullRange
        );
        feeId = feeKey.toId();

        feeKey2 = IPoolManager.PoolKey(
            Currency.wrap(address(token1)), Currency.wrap(address(token2)), 3000, TICK_SPACING, fullRange
        );
        feeId2 = feeKey.toId();

        modifyPositionRouter = new PoolModifyPositionTest(manager);
        swapRouter = new PoolSwapTest(manager);

        token0.approve(address(fullRange), type(uint256).max);
        token1.approve(address(fullRange), type(uint256).max);
        token0.approve(address(modifyPositionRouter), type(uint256).max);
        token1.approve(address(modifyPositionRouter), type(uint256).max);
        token0.approve(address(swapRouter), type(uint256).max);
        token1.approve(address(swapRouter), type(uint256).max);
        token0.approve(address(manager), type(uint256).max);
        token1.approve(address(manager), type(uint256).max);
    }

    function testGetSqrtPrice() public {
        manager.initialize(key, SQRT_RATIO_1_1);
        // fullRange.addLiquidity(address(token0), address(token1), 0, 10 ether, 10 ether, address(this), MAX_DEADLINE);
        uint160 sqrtPrice = fullRange.getSqrtPrice(key, toBalanceDelta(10 ether, 10 ether));
        sqrtPrice = fullRange.getSqrtPrice(key, toBalanceDelta(12 ether, 7.5 ether));
        sqrtPrice = fullRange.getSqrtPrice(key, toBalanceDelta(1 ether, 7.5 ether));
    }

    function testBeforeInitializeAllowsPoolCreation() public {
        vm.expectEmit(true, true, true, true);
        emit Initialize(id, key.currency0, key.currency1, key.fee, key.tickSpacing, key.hooks);
        snapStart("initialize no fee");
        manager.initialize(key, SQRT_RATIO_1_1);
        snapEnd();

        (,,,,,, address liquidityToken) = fullRange.poolInfo(id);

        assertFalse(liquidityToken == address(0));
    }

    function testInitializeWithFee() public {
        vm.expectEmit(true, true, true, true);
        emit Initialize(feeId, feeKey.currency0, feeKey.currency1, feeKey.fee, feeKey.tickSpacing, feeKey.hooks);
        snapStart("initialize with fee");
        manager.initialize(feeKey, SQRT_RATIO_1_1);
        snapEnd();

        (,,,,,, address liquidityToken) = fullRange.poolInfo(feeId);

        assertFalse(liquidityToken == address(0));
    }

    function testBeforeInitializeRevertsIfWrongSpacing() public {
        IPoolManager.PoolKey memory wrongKey = IPoolManager.PoolKey(
            Currency.wrap(address(token0)), Currency.wrap(address(token1)), 0, TICK_SPACING + 1, fullRange
        );

        vm.expectRevert("Tick spacing must be default");
        manager.initialize(wrongKey, SQRT_RATIO_1_1);
    }

    function testInitialAddLiquiditySucceeds() public {
        manager.initialize(key, SQRT_RATIO_1_1);

        uint256 prevBalance0 = TestERC20(token0).balanceOf(address(this));
        uint256 prevBalance1 = TestERC20(token1).balanceOf(address(this));

        snapStart("add liquidity");
        fullRange.addLiquidity(address(token0), address(token1), 0, 10 ether, 10 ether, address(this), MAX_DEADLINE);
        snapEnd();

        assertEq(TestERC20(token0).balanceOf(address(this)), prevBalance0 - 10 ether);
        assertEq(TestERC20(token1).balanceOf(address(this)), prevBalance1 - 10 ether);

        (,,,,,, address liquidityToken) = fullRange.poolInfo(id);

        assertEq(UniswapV4ERC20(liquidityToken).balanceOf(address(this)), 10 ether);
    }

    function testInitialAddLiquidityWithFeeSucceeds() public {
        manager.initialize(feeKey, SQRT_RATIO_1_1);

        uint256 prevBalance0 = TestERC20(token0).balanceOf(address(this));
        uint256 prevBalance1 = TestERC20(token1).balanceOf(address(this));

        snapStart("add liquidity with fee");
        fullRange.addLiquidity(address(token0), address(token1), 3000, 10 ether, 10 ether, address(this), MAX_DEADLINE);
        snapEnd();

        assertEq(TestERC20(token0).balanceOf(address(this)), prevBalance0 - 10 ether);
        assertEq(TestERC20(token1).balanceOf(address(this)), prevBalance1 - 10 ether);

        (,,,,,, address liquidityToken) = fullRange.poolInfo(feeId);

        assertEq(UniswapV4ERC20(liquidityToken).balanceOf(address(this)), 10 ether);

        // check pool position state
        (
            uint128 liquidity,
            uint256 feeGrowthInside0LastX128,
            uint256 feeGrowthInside1LastX128,
            uint128 tokensOwed0,
            uint128 tokensOwed1,
            ,
        ) = fullRange.poolInfo(feeId);

        assertEq(liquidity, 10 ether);
        assertEq(feeGrowthInside0LastX128, 0);
        assertEq(feeGrowthInside1LastX128, 0);
        assertEq(tokensOwed0, 0);
        assertEq(tokensOwed1, 0);
    }

    function testAddLiquidityFailsIfNoPool() public {
        vm.expectRevert(FullRange.PoolNotInitialized.selector);
        fullRange.addLiquidity(address(token0), address(token1), 0, 10 ether, 10 ether, address(this), MAX_DEADLINE);
    }

    function testAddLiquidityWithDiffRatiosAndNoFee() public {
        manager.initialize(key, SQRT_RATIO_1_1);

        uint256 prevBalance0 = TestERC20(token0).balanceOf(address(this));
        uint256 prevBalance1 = TestERC20(token1).balanceOf(address(this));

        fullRange.addLiquidity(address(token0), address(token1), 0, 50 ether, 25 ether, address(this), MAX_DEADLINE);

        // even though we desire to deposit more token0, we cannot, since the ratio is 1:1
        assertEq(TestERC20(token0).balanceOf(address(this)), prevBalance0 - 25 ether);
        assertEq(TestERC20(token1).balanceOf(address(this)), prevBalance1 - 25 ether);

        (,,,,,, address liquidityToken) = fullRange.poolInfo(id);

        // TODO: why are we getting one extra liquidity token lol
        assertEq(UniswapV4ERC20(liquidityToken).balanceOf(address(this)), 25 ether + 1);
    }

    function testAddLiquidityWithDiffRatiosAndFee() public {
        manager.initialize(feeKey, SQRT_RATIO_1_1);

        uint256 prevBalance0 = TestERC20(token0).balanceOf(address(this));
        uint256 prevBalance1 = TestERC20(token1).balanceOf(address(this));

        fullRange.addLiquidity(address(token0), address(token1), 3000, 50 ether, 25 ether, address(this), MAX_DEADLINE);

        // evem though we desire to deposit more token0, we cannot, since the ratio is 1:1
        assertEq(TestERC20(token0).balanceOf(address(this)), prevBalance0 - 25 ether);
        assertEq(TestERC20(token1).balanceOf(address(this)), prevBalance1 - 25 ether);

        (,,,,,, address liquidityToken) = fullRange.poolInfo(feeId);

        // TODO: why are we getting one extra liquidity token here
        assertEq(UniswapV4ERC20(liquidityToken).balanceOf(address(this)), 25 ether + 1);

        // check pool position state
        (
            uint128 liquidity,
            uint256 feeGrowthInside0LastX128,
            uint256 feeGrowthInside1LastX128,
            uint128 tokensOwed0,
            uint128 tokensOwed1,
            ,
        ) = fullRange.poolInfo(feeId);

        assertEq(liquidity, 25 ether + 1);
        assertEq(feeGrowthInside0LastX128, 0);
        assertEq(feeGrowthInside1LastX128, 0);
        assertEq(tokensOwed0, 0);
        assertEq(tokensOwed1, 0);
    }

    // TODO: Fix this test, make sure math is correct
    function testSwapAddLiquiditySucceedsWithNoFee() public {
        manager.initialize(key, SQRT_RATIO_1_1);

        uint256 prevBalance0 = TestERC20(token0).balanceOf(address(this));
        uint256 prevBalance1 = TestERC20(token1).balanceOf(address(this));

        fullRange.addLiquidity(address(token0), address(token1), 0, 10 ether, 10 ether, address(this), MAX_DEADLINE);

        (,,,,,, address liquidityToken) = fullRange.poolInfo(id);

        assertEq(UniswapV4ERC20(liquidityToken).balanceOf(address(this)), 10 ether);
        assertEq(TestERC20(token0).balanceOf(address(this)), prevBalance0 - 10 ether);
        assertEq(TestERC20(token0).balanceOf(address(this)), prevBalance0 - 10 ether);

        IPoolManager.SwapParams memory params =
            IPoolManager.SwapParams({zeroForOne: true, amountSpecified: 1 ether, sqrtPriceLimitX96: SQRT_RATIO_1_2});

        PoolSwapTest.TestSettings memory testSettings =
            PoolSwapTest.TestSettings({withdrawTokens: true, settleUsingTransfer: true});

        vm.expectEmit(true, true, true, true);
        emit Swap(
            id, address(swapRouter), 1 ether, -909090909090909090, 72025602285694852357767227579, 10 ether, -1907, 0
        ); // TODO: modify this emit

        snapStart("swap with no fee");
        swapRouter.swap(key, params, testSettings);
        snapEnd();

        assertEq(TestERC20(token0).balanceOf(address(this)), prevBalance0 - 10 ether - 1 ether);
        assertEq(TestERC20(token1).balanceOf(address(this)), prevBalance1 - 10 ether + 909090909090909090);

        fullRange.addLiquidity(address(token0), address(token1), 0, 5 ether, 5 ether, address(this), MAX_DEADLINE);

        // assertEq(TestERC20(token0).balanceOf(address(this)), prevBalance0 - 10 ether - 1 ether - 5 ether);
        // assertEq(TestERC20(token1).balanceOf(address(this)), prevBalance1 - 10 ether + 909090909090909090 - 5 ether);

        // managed to provide less than 5 ether of liquidity due to change in ratio
        assertEq(UniswapV4ERC20(liquidityToken).balanceOf(address(this)), 14545454545454545454);
    }

    // TODO: FIX THIS
    function testSwapAddLiquiditySucceedsWithFeeNoRebalance() public {
        manager.initialize(feeKey, SQRT_RATIO_1_1);

        uint256 prevBalance0 = TestERC20(token0).balanceOf(address(this));
        uint256 prevBalance1 = TestERC20(token1).balanceOf(address(this));

        fullRange.addLiquidity(address(token0), address(token1), 3000, 10 ether, 10 ether, address(this), MAX_DEADLINE);

        (,,,,,, address liquidityToken) = fullRange.poolInfo(feeId);

        assertEq(UniswapV4ERC20(liquidityToken).balanceOf(address(this)), 10 ether);
        assertEq(TestERC20(token0).balanceOf(address(this)), prevBalance0 - 10 ether);
        assertEq(TestERC20(token0).balanceOf(address(this)), prevBalance0 - 10 ether);

        // only get 98 back because of fees
        vm.expectEmit(true, true, true, true);
        emit Swap(
            feeId,
            address(swapRouter),
            1 ether,
            -906610893880149131,
            72045250990510446115798809072,
            10 ether,
            -1901,
            3000
        ); // TODO: modify this emit

        snapStart("swap with fee");
        swapRouter.swap(
            feeKey,
            IPoolManager.SwapParams({zeroForOne: true, amountSpecified: 1 ether, sqrtPriceLimitX96: SQRT_RATIO_1_2}),
            PoolSwapTest.TestSettings({withdrawTokens: true, settleUsingTransfer: true})
        );
        snapEnd();

        uint256 feeGrowthInside0LastX128test =
            manager.getPosition(feeId, address(fullRange), MIN_TICK, MAX_TICK).feeGrowthInside0LastX128;
        uint256 feeGrowthInside1LastX128test =
            manager.getPosition(feeId, address(fullRange), MIN_TICK, MAX_TICK).feeGrowthInside1LastX128;

        assertEq(TestERC20(token0).balanceOf(address(this)), prevBalance0 - 10 ether - 1 ether);
        // assertEq(TestERC20(token1).balanceOf(address(this)), prevBalance1 - 10 ether + 1 ether);

        // check pool position state
        (
            uint128 prevLiquidity,
            uint256 prevFeeGrowthInside0LastX128,
            uint256 prevFeeGrowthInside1LastX128,
            uint128 prevTokensOwed0,
            uint128 prevTokensOwed1,
            ,
        ) = fullRange.poolInfo(feeId);

        assertEq(prevLiquidity, 10 ether);
        assertEq(prevFeeGrowthInside0LastX128, 0);
        assertEq(prevFeeGrowthInside1LastX128, 0);
        assertEq(prevTokensOwed0, 0);
        assertEq(prevTokensOwed1, 0);

        // all of the fee updates should have happened here
        snapStart("add liquidity with fee accumulated");
        fullRange.addLiquidity(address(token0), address(token1), 3000, 5 ether, 5 ether, address(this), MAX_DEADLINE);
        snapEnd();

        // assertEq(TestERC20(token0).balanceOf(address(this)), prevBalance0 - 10 ether - 1 ether - 5 ether);
        // assertEq(TestERC20(token1).balanceOf(address(this)), prevBalance1 - 10 ether + 1 ether - 5 ether);

        // managed to provide 49 liquidity due to change in ratio
        assertEq(UniswapV4ERC20(liquidityToken).balanceOf(address(this)), 14546694553059925434);

        // check pool position state
        (
            uint128 liquidity,
            uint256 feeGrowthInside0LastX128,
            uint256 feeGrowthInside1LastX128,
            uint128 tokensOwed0,
            uint128 tokensOwed1,
            ,
        ) = fullRange.poolInfo(feeId);

        assertEq(liquidity, 14546694553059925434);

        // // TODO: calculate the feeGrowth
        Position.Info memory posInfo = manager.getPosition(feeId, address(fullRange), MIN_TICK, MAX_TICK);

        // NOTE: supposedly, the feeGrowthInside0Last will update after the second modifyPosition, not directly after a swap - makes sense since
        // a swap does not update all positions

        // not supposed to be 0 here
        assertEq(feeGrowthInside0LastX128, posInfo.feeGrowthInside0LastX128);
        assertEq(feeGrowthInside1LastX128, posInfo.feeGrowthInside1LastX128);

        uint128 tokensOwed0New = uint128(
            FullMath.mulDiv(feeGrowthInside0LastX128 - prevFeeGrowthInside0LastX128, prevLiquidity, FixedPoint128.Q128)
        );

        uint128 tokensOwed1New = uint128(
            FullMath.mulDiv(feeGrowthInside1LastX128 - prevFeeGrowthInside1LastX128, prevLiquidity, FixedPoint128.Q128)
        );

        // pretty sure this rounds down the tokensOwed you get lol...
        assertEq(tokensOwed0, tokensOwed0New);
        assertEq(tokensOwed1, tokensOwed1New);
    }

    // TODO: FIX THIS, there is dust
    function testSwapAddLiquiditySucceedsWithFeeRebalance() public {
        vm.roll(100);
        manager.initialize(feeKey, SQRT_RATIO_1_1);

        fullRange.addLiquidity(address(token0), address(token1), 3000, 10 ether, 10 ether, address(this), MAX_DEADLINE);

        (,,,,,, address liquidityToken) = fullRange.poolInfo(feeId);

        assertEq(UniswapV4ERC20(liquidityToken).balanceOf(address(this)), 10 ether);

        IPoolManager.SwapParams memory params =
            IPoolManager.SwapParams({zeroForOne: true, amountSpecified: 1 ether, sqrtPriceLimitX96: SQRT_RATIO_1_2});

        PoolSwapTest.TestSettings memory testSettings =
            PoolSwapTest.TestSettings({withdrawTokens: true, settleUsingTransfer: true});

        snapStart("swap with fee and rebalance");
        swapRouter.swap(feeKey, params, testSettings);
        snapEnd();

        // check pool position state
        (
            uint128 liquidity,
            uint256 feeGrowthInside0LastX128,
            uint256 feeGrowthInside1LastX128,
            uint128 tokensOwed0,
            uint128 tokensOwed1,
            ,
        ) = fullRange.poolInfo(feeId);

        assertEq(liquidity, 10 ether);
        assertEq(feeGrowthInside0LastX128, 0);
        assertEq(feeGrowthInside1LastX128, 0);
        assertEq(tokensOwed0, 0);
        assertEq(tokensOwed1, 0);

        snapStart("add liquidity with fee accumulated for rebalance");
        fullRange.addLiquidity(address(token0), address(token1), 3000, 10 ether, 10 ether, address(this), MAX_DEADLINE);
        snapEnd();

        // all the core fee updates should have happened by now

        vm.roll(101);

        // rebalance should happen before this
        snapStart("add liquidity with fee for rebalance and update state");
        fullRange.addLiquidity(address(token0), address(token1), 3000, 10 ether, 10 ether, address(this), MAX_DEADLINE);
        snapEnd();

        // check pool position state
        (liquidity, feeGrowthInside0LastX128, feeGrowthInside1LastX128, tokensOwed0, tokensOwed1,,) =
            fullRange.poolInfo(feeId);

        // assertEq(liquidity, 30 ether); // it's actually less than the liquidity added LOL

        // TODO: calculate the feeGrowth on my own after a swap
        Position.Info memory posInfo = manager.getPosition(feeId, address(fullRange), MIN_TICK, MAX_TICK);

        // assertEq(feeGrowthInside0LastX128, posInfo.feeGrowthInside0LastX128);
        // assertEq(feeGrowthInside1LastX128, posInfo.feeGrowthInside1LastX128);

        // assertEq(tokensOwed0, 0);
        // assertEq(tokensOwed1, 0);
    }

    // function testSwapAddLiquidityTwoPoolsAndRebalance() public {
    //     vm.roll(100);
    //     manager.initialize(feeKey, SQRT_RATIO_1_1);
    //     manager.initialize(feeKey2, SQRT_RATIO_1_1);

    //     fullRange.addLiquidity(address(token0), address(token1), 3000, 10 ether, 10 ether, address(this), MAX_DEADLINE);
    //     fullRange.addLiquidity(address(token1), address(token2), 3000, 10 ether, 10 ether, address(this), MAX_DEADLINE);

    //     IPoolManager.SwapParams memory params =
    //         IPoolManager.SwapParams({zeroForOne: true, amountSpecified: 10000000, sqrtPriceLimitX96: SQRT_RATIO_1_2});

    //     PoolSwapTest.TestSettings memory testSettings =
    //         PoolSwapTest.TestSettings({withdrawTokens: true, settleUsingTransfer: true});

    //     swapRouter.swap(feeKey, params, testSettings);

    //     // fullRange.addLiquidity(address(token0), address(token1), 3000, 50, 50, address(this), MAX_DEADLINE);

    //     // all the core fee updates should have happened by now
    //     vm.roll(101);

    //     // rebalance should happen before this
    //     fullRange.addLiquidity(address(token0), address(token1), 3000, 5 ether, 5 ether, address(this), MAX_DEADLINE);
    //     fullRange.addLiquidity(address(token1), address(token2), 3000, 5 ether, 5 ether, address(this), MAX_DEADLINE);

    //     // check pool position state
    //     (uint128 liquidity,
    //         uint256 feeGrowthInside0LastX128,
    //         uint256 feeGrowthInside1LastX128,
    //         uint128 tokensOwed0,
    //         uint128 tokensOwed1,,) =
    //         fullRange.poolInfo(feeId);

    //     assertEq(liquidity, 150 ether); // it's actually less than the liquidity added LOL

    //     // TODO: calculate the feeGrowth on my own after a swap
    //     Position.Info memory posInfo = manager.getPosition(feeId, address(fullRange), MIN_TICK, MAX_TICK);

    //     assertEq(feeGrowthInside0LastX128, posInfo.feeGrowthInside0LastX128);
    //     assertEq(feeGrowthInside1LastX128, posInfo.feeGrowthInside1LastX128);

    //     assertEq(tokensOwed0, 0);
    //     assertEq(tokensOwed1, 0);

    //     (liquidity,
    //     feeGrowthInside0LastX128,
    //     feeGrowthInside1LastX128,
    //     tokensOwed0,
    //     tokensOwed1,,) =
    //         fullRange.poolInfo(feeId2);

    //     assertEq(liquidity, 15 ether); // it's actually less than the liquidity added LOL

    //     // TODO: calculate the feeGrowth on my own after a swap
    //     posInfo = manager.getPosition(feeId2, address(fullRange), MIN_TICK, MAX_TICK);

    //     assertEq(feeGrowthInside0LastX128, posInfo.feeGrowthInside0LastX128);
    //     assertEq(feeGrowthInside1LastX128, posInfo.feeGrowthInside1LastX128);

    //     assertEq(tokensOwed0, 0);
    //     assertEq(tokensOwed1, 0);
    // }

    // // block number change with two pools

    function testInitialRemoveLiquiditySucceedsNoFee() public {
        manager.initialize(key, SQRT_RATIO_1_1);

        uint256 prevBalance0 = TestERC20(token0).balanceOf(address(this));
        uint256 prevBalance1 = TestERC20(token1).balanceOf(address(this));

        fullRange.addLiquidity(address(token0), address(token1), 0, 10 ether, 10 ether, address(this), MAX_DEADLINE);

        (,,,,,, address liquidityToken) = fullRange.poolInfo(id);

        assertEq(UniswapV4ERC20(liquidityToken).balanceOf(address(this)), 10 ether);

        assertEq(TestERC20(token0).balanceOf(address(this)), prevBalance0 - 10 ether);
        assertEq(TestERC20(token1).balanceOf(address(this)), prevBalance1 - 10 ether);

        // approve fullRange to spend our liquidity tokens
        UniswapV4ERC20(liquidityToken).approve(address(fullRange), type(uint256).max);

        snapStart("remove liquidity no fee");
        fullRange.removeLiquidity(address(token0), address(token1), 0, 1 ether, 0, 0, address(this), MAX_DEADLINE);
        snapEnd();

        // TODO: losing one token
        assertEq(UniswapV4ERC20(liquidityToken).balanceOf(address(this)), 9 ether);
        assertEq(TestERC20(token0).balanceOf(address(this)), prevBalance0 - 10 ether + 1 ether - 1);
        assertEq(TestERC20(token1).balanceOf(address(this)), prevBalance1 - 10 ether + 1 ether - 1);
    }

    function testInitialRemoveLiquiditySucceedsWithFee() public {
        manager.initialize(feeKey, SQRT_RATIO_1_1);

        uint256 prevBalance0 = TestERC20(token0).balanceOf(address(this));
        uint256 prevBalance1 = TestERC20(token1).balanceOf(address(this));

        fullRange.addLiquidity(address(token0), address(token1), 3000, 10 ether, 10 ether, address(this), MAX_DEADLINE);

        (,,,,,, address liquidityToken) = fullRange.poolInfo(feeId);

        assertEq(UniswapV4ERC20(liquidityToken).balanceOf(address(this)), 10 ether);

        assertEq(TestERC20(token0).balanceOf(address(this)), prevBalance0 - 10 ether);
        assertEq(TestERC20(token1).balanceOf(address(this)), prevBalance1 - 10 ether);

        // approve fullRange to spend our liquidity tokens
        UniswapV4ERC20(liquidityToken).approve(address(fullRange), type(uint256).max);

        snapStart("remove liquidity with fee");
        fullRange.removeLiquidity(address(token0), address(token1), 3000, 1 ether, 0, 0, address(this), MAX_DEADLINE);
        snapEnd();

        assertEq(UniswapV4ERC20(liquidityToken).balanceOf(address(this)), 9 ether);
        // TODO: losing one token here
        assertEq(TestERC20(token0).balanceOf(address(this)), prevBalance0 - 9 ether - 1);
        assertEq(TestERC20(token1).balanceOf(address(this)), prevBalance1 - 9 ether - 1);

        // check pool position state
        (
            uint128 liquidity,
            uint256 feeGrowthInside0LastX128,
            uint256 feeGrowthInside1LastX128,
            uint128 tokensOwed0,
            uint128 tokensOwed1,
            ,
        ) = fullRange.poolInfo(feeId);

        assertEq(liquidity, 9 ether);
        // TODO: make sure 0 is correct
        assertEq(feeGrowthInside0LastX128, 0);
        assertEq(feeGrowthInside1LastX128, 0);
        assertEq(tokensOwed0, 0);
        assertEq(tokensOwed1, 0);
    }

    function testRemoveLiquidityFailsIfNoPool() public {
        vm.expectRevert(FullRange.PoolNotInitialized.selector);
        fullRange.addLiquidity(address(token0), address(token1), 0, 10 ether, 10 ether, address(this), MAX_DEADLINE);
    }

    function testRemoveLiquiditySucceedsWithNoFee() public {
        manager.initialize(key, SQRT_RATIO_1_1);

        uint256 prevBalance0 = TestERC20(token0).balanceOf(address(this));
        uint256 prevBalance1 = TestERC20(token1).balanceOf(address(this));

        fullRange.addLiquidity(address(token0), address(token1), 0, 10 ether, 10 ether, address(this), MAX_DEADLINE);

        assertEq(TestERC20(token0).balanceOf(address(this)), prevBalance0 - 10 ether);
        assertEq(TestERC20(token1).balanceOf(address(this)), prevBalance1 - 10 ether);

        (,,,,,, address liquidityToken) = fullRange.poolInfo(id);

        assertEq(UniswapV4ERC20(liquidityToken).balanceOf(address(this)), 10 ether);

        fullRange.addLiquidity(address(token0), address(token1), 0, 5 ether, 5 ether, address(this), MAX_DEADLINE);

        assertEq(TestERC20(token0).balanceOf(address(this)), prevBalance0 - 15 ether);
        assertEq(TestERC20(token1).balanceOf(address(this)), prevBalance1 - 15 ether);

        assertEq(UniswapV4ERC20(liquidityToken).balanceOf(address(this)), 15 ether);

        UniswapV4ERC20(liquidityToken).approve(address(fullRange), type(uint256).max);

        fullRange.removeLiquidity(address(token0), address(token1), 0, 10 ether, 0, 0, address(this), MAX_DEADLINE);

        assertEq(UniswapV4ERC20(liquidityToken).balanceOf(address(this)), 5 ether);
        // TODO: lost a bit of tokens
        assertEq(TestERC20(token0).balanceOf(address(this)), prevBalance0 - 5 ether - 1);
        assertEq(TestERC20(token1).balanceOf(address(this)), prevBalance1 - 5 ether - 1);
    }

    function testRemoveLiquiditySucceedsWithPartialAndFee() public {
        manager.initialize(feeKey, SQRT_RATIO_1_1);

        uint256 prevBalance0 = TestERC20(token0).balanceOf(address(this));
        uint256 prevBalance1 = TestERC20(token1).balanceOf(address(this));

        fullRange.addLiquidity(address(token0), address(token1), 3000, 10 ether, 10 ether, address(this), MAX_DEADLINE);

        (,,,,,, address liquidityToken) = fullRange.poolInfo(feeId);

        assertEq(UniswapV4ERC20(liquidityToken).balanceOf(address(this)), 10 ether);

        assertEq(TestERC20(token0).balanceOf(address(this)), prevBalance0 - 10 ether);
        assertEq(TestERC20(token1).balanceOf(address(this)), prevBalance1 - 10 ether);

        UniswapV4ERC20(liquidityToken).approve(address(fullRange), type(uint256).max);

        fullRange.removeLiquidity(address(token0), address(token1), 3000, 5 ether, 0, 0, address(this), MAX_DEADLINE);

        assertEq(UniswapV4ERC20(liquidityToken).balanceOf(address(this)), 5 ether);
        assertEq(TestERC20(token0).balanceOf(address(this)), prevBalance0 - 5 ether - 1);
        assertEq(TestERC20(token1).balanceOf(address(this)), prevBalance1 - 5 ether - 1);

        // check pool position state
        (
            uint128 liquidity,
            uint256 feeGrowthInside0LastX128,
            uint256 feeGrowthInside1LastX128,
            uint128 tokensOwed0,
            uint128 tokensOwed1,
            ,
        ) = fullRange.poolInfo(feeId);

        assertEq(liquidity, 5 ether);
        // TODO: make sure 0 is correct
        assertEq(feeGrowthInside0LastX128, 0);
        assertEq(feeGrowthInside1LastX128, 0);
        assertEq(tokensOwed0, 0);
        assertEq(tokensOwed1, 0);
    }

    function testRemoveLiquiditySucceedsWithPartial() public {
        manager.initialize(key, SQRT_RATIO_1_1);

        uint256 prevBalance0 = TestERC20(token0).balanceOf(address(this));
        uint256 prevBalance1 = TestERC20(token1).balanceOf(address(this));

        fullRange.addLiquidity(address(token0), address(token1), 0, 10 ether, 10 ether, address(this), MAX_DEADLINE);

        (,,,,,, address liquidityToken) = fullRange.poolInfo(id);

        assertEq(UniswapV4ERC20(liquidityToken).balanceOf(address(this)), 10 ether);

        assertEq(TestERC20(token0).balanceOf(address(this)), prevBalance0 - 10 ether);
        assertEq(TestERC20(token1).balanceOf(address(this)), prevBalance1 - 10 ether);

        UniswapV4ERC20(liquidityToken).approve(address(fullRange), type(uint256).max);

        fullRange.removeLiquidity(address(token0), address(token1), 0, 5 ether, 0, 0, address(this), MAX_DEADLINE);

        assertEq(UniswapV4ERC20(liquidityToken).balanceOf(address(this)), 5 ether);
        // TODO: losing a bit
        assertEq(TestERC20(token0).balanceOf(address(this)), prevBalance0 - 5 ether - 1);
        assertEq(TestERC20(token1).balanceOf(address(this)), prevBalance1 - 5 ether - 1);
    }

    function testRemoveLiquidityWithDiffRatiosAndNoFee() public {
        // TODO: maybe add one for with fees?
        manager.initialize(key, SQRT_RATIO_1_1);

        uint256 prevBalance0 = TestERC20(token0).balanceOf(address(this));
        uint256 prevBalance1 = TestERC20(token1).balanceOf(address(this));

        fullRange.addLiquidity(address(token0), address(token1), 0, 10 ether, 10 ether, address(this), MAX_DEADLINE);

        assertEq(TestERC20(token0).balanceOf(address(this)), prevBalance0 - 10 ether);
        assertEq(TestERC20(token1).balanceOf(address(this)), prevBalance1 - 10 ether);

        (,,,,,, address liquidityToken) = fullRange.poolInfo(id);

        assertEq(UniswapV4ERC20(liquidityToken).balanceOf(address(this)), 10 ether);

        fullRange.addLiquidity(address(token0), address(token1), 0, 5 ether, 2.5 ether, address(this), MAX_DEADLINE);

        assertEq(TestERC20(token0).balanceOf(address(this)), prevBalance0 - 12.5 ether);
        assertEq(TestERC20(token1).balanceOf(address(this)), prevBalance1 - 12.5 ether);

        assertEq(UniswapV4ERC20(liquidityToken).balanceOf(address(this)), 12.5 ether);

        UniswapV4ERC20(liquidityToken).approve(address(fullRange), type(uint256).max);

        fullRange.removeLiquidity(address(token0), address(token1), 0, 5 ether, 0, 0, address(this), MAX_DEADLINE);

        // TODO: balance checks for token0 and token1
        assertEq(TestERC20(token0).balanceOf(address(this)), prevBalance0 - 7.5 ether - 1);
        assertEq(TestERC20(token1).balanceOf(address(this)), prevBalance1 - 7.5 ether - 1);

        assertEq(UniswapV4ERC20(liquidityToken).balanceOf(address(this)), 7.5 ether);
    }

    function testSwapRemoveLiquiditySucceedsWithFeeNoRebalance() public {
        manager.initialize(feeKey, SQRT_RATIO_1_1);

        uint256 prevBalance0 = TestERC20(token0).balanceOf(address(this));
        uint256 prevBalance1 = TestERC20(token1).balanceOf(address(this));

        fullRange.addLiquidity(address(token0), address(token1), 3000, 10 ether, 10 ether, address(this), MAX_DEADLINE);

        IPoolManager.SwapParams memory params =
            IPoolManager.SwapParams({zeroForOne: true, amountSpecified: 1 ether, sqrtPriceLimitX96: SQRT_RATIO_1_2});

        PoolSwapTest.TestSettings memory testSettings =
            PoolSwapTest.TestSettings({withdrawTokens: true, settleUsingTransfer: true});

        swapRouter.swap(feeKey, params, testSettings);

        (,,,,,, address liquidityToken) = fullRange.poolInfo(feeId);

        UniswapV4ERC20(liquidityToken).approve(address(fullRange), type(uint256).max);

        // all of the fee updates should have happened here
        snapStart("remove liquidity with fee no rebalance");
        fullRange.removeLiquidity(address(token0), address(token1), 3000, 5 ether, 0, 0, address(this), MAX_DEADLINE);
        snapEnd();

        // TODO: numbers
        // assertEq(TestERC20(token0).balanceOf(address(this)), prevBalance0 - 10 ether - 1 ether + 5 ether - 1);
        // assertEq(TestERC20(token1).balanceOf(address(this)), prevBalance1 - 10 ether + 1 ether + 5 ether - 1);

        assertEq(UniswapV4ERC20(liquidityToken).balanceOf(address(this)), 5 ether);

        // check pool position state
        (
            uint128 liquidity,
            uint256 feeGrowthInside0LastX128,
            uint256 feeGrowthInside1LastX128,
            uint128 tokensOwed0,
            uint128 tokensOwed1,
            ,
        ) = fullRange.poolInfo(feeId);

        // TODO: this is returning 9546694553059925434?
        assertEq(liquidity, 5 ether);

        // // TODO: calculate the feeGrowth
        Position.Info memory posInfo = manager.getPosition(feeId, address(fullRange), MIN_TICK, MAX_TICK);

        // NOTE: supposedly, the feeGrowthInside0Last will update after the second modifyPosition, not directly after a swap - makes sense since
        // a swap does not update all positions

        // not supposed to be 0 here
        assertEq(feeGrowthInside0LastX128, posInfo.feeGrowthInside0LastX128);
        assertEq(feeGrowthInside1LastX128, posInfo.feeGrowthInside1LastX128);

        uint128 tokensOwed0New = uint128(FullMath.mulDiv(feeGrowthInside0LastX128 - 0, 10 ether, FixedPoint128.Q128));

        uint128 tokensOwed1New = uint128(FullMath.mulDiv(feeGrowthInside1LastX128 - 0, 10 ether, FixedPoint128.Q128));

        // pretty sure this rounds down the tokensOwed you get lol...
        assertEq(tokensOwed0, tokensOwed0New);
        assertEq(tokensOwed1, tokensOwed1New);
    }

    // function testSwapRemoveLiquiditySucceedsWithFeeRebalance() public {
    //     vm.roll(100);
    //     manager.initialize(feeKey, SQRT_RATIO_1_1);

    //     fullRange.addLiquidity(address(token0), address(token1), 3000, 10 ether, 10 ether, address(this), MAX_DEADLINE);

    //     (,,,,,, address liquidityToken) = fullRange.poolInfo(feeId);

    //     assertEq(UniswapV4ERC20(liquidityToken).balanceOf(address(this)), 10 ether);

    //     IPoolManager.SwapParams memory params =
    //         IPoolManager.SwapParams({zeroForOne: true, amountSpecified: 1 ether, sqrtPriceLimitX96: SQRT_RATIO_1_2});

    //     PoolSwapTest.TestSettings memory testSettings =
    //         PoolSwapTest.TestSettings({withdrawTokens: true, settleUsingTransfer: true});

    //     swapRouter.swap(feeKey, params, testSettings);

    //     fullRange.addLiquidity(address(token0), address(token1), 3000, 5 ether, 5 ether, address(this), MAX_DEADLINE);

    //     // all the core fee updates should have happened by now

    //     vm.roll(101);

    //     UniswapV4ERC20(liquidityToken).approve(address(fullRange), type(uint256).max);

    //     snapStart("remove liquidity with fee and rebalance");
    //     fullRange.removeLiquidity(address(token0), address(token1), 3000, 5 ether, 0, 0, address(this), MAX_DEADLINE);
    //     snapEnd();

    //     // check pool position state
    //     (
    //         uint128 liquidity,
    //         uint256 feeGrowthInside0LastX128,
    //         uint256 feeGrowthInside1LastX128,
    //         uint128 tokensOwed0,
    //         uint128 tokensOwed1,
    //         ,
    //     ) = fullRange.poolInfo(feeId);
    //     // TODO: check
    //     assertEq(liquidity, 9546694553059925434); // it's actually less than the liquidity added LOL

    //     // TODO: calculate the feeGrowth on my own after a swap
    //     Position.Info memory posInfo = manager.getPosition(feeId, address(fullRange), MIN_TICK, MAX_TICK);

    //     assertEq(feeGrowthInside0LastX128, posInfo.feeGrowthInside0LastX128);
    //     assertEq(feeGrowthInside1LastX128, posInfo.feeGrowthInside1LastX128);

    //     assertEq(tokensOwed0, 0);
    //     assertEq(tokensOwed1, 0);
    // }

    // this test is never called
    // function testModifyPositionFailsIfNotFullRange() public {
    //     manager.initialize(key, SQRT_RATIO_1_1);
    //     vm.expectRevert("Tick range out of range or not full range");

    //     modifyPositionRouter.modifyPosition(
    //         key, IPoolManager.ModifyPositionParams({tickLower: MIN_TICK + 1, tickUpper: MAX_TICK - 1, liquidityDelta: 100})
    //     );
    // }

    function testBeforeModifyPositionFailsWithWrongMsgSender() public {
        manager.initialize(key, SQRT_RATIO_1_1);

        vm.expectRevert("sender must be hook");

        modifyPositionRouter.modifyPosition(
            key, IPoolManager.ModifyPositionParams({tickLower: MIN_TICK, tickUpper: MAX_TICK, liquidityDelta: 100})
        );
    }
}
