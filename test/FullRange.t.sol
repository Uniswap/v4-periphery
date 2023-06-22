// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {Test} from "forge-std/Test.sol";
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

import "forge-std/console.sol";

contract TestFullRange is Test, Deployers {
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

    /// @dev Min tick for full range with tick spacing of 60
    int24 internal constant MIN_TICK = -887220;
    /// @dev Max tick for full range with tick spacing of 60
    int24 internal constant MAX_TICK = -MIN_TICK;

    TestERC20 token0;
    TestERC20 token1;
    PoolManager manager;
    FullRangeImplementation fullRange = FullRangeImplementation(
        address(uint160(Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_MODIFY_POSITION_FLAG | Hooks.BEFORE_SWAP_FLAG))
    );
    IPoolManager.PoolKey key;
    PoolId id;

    // the key that includes a pool fee for pool fee rebalance tests
    IPoolManager.PoolKey feeKey;
    PoolId feeId;

    PoolModifyPositionTest modifyPositionRouter;
    PoolSwapTest swapRouter;

    function setUp() public {
        token0 = new TestERC20(2**128);
        token1 = new TestERC20(2**128);
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

    function testBeforeInitializeAllowsPoolCreation() public {
        vm.expectEmit(true, true, true, true);
        emit Initialize(id, key.currency0, key.currency1, key.fee, key.tickSpacing, key.hooks);
        manager.initialize(key, SQRT_RATIO_1_1);

        // check that address is in mapping
        assertFalse(fullRange.poolToERC20(id) == address(0));
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

        uint256 currBalance0 = TestERC20(token0).balanceOf(address(this));
        uint256 currBalance1 = TestERC20(token1).balanceOf(address(this));

        fullRange.addLiquidity(address(token0), address(token1), 0, 100, 100, address(this), 12329839823);

        assertEq(TestERC20(token0).balanceOf(address(this)), currBalance0 - 100);
        assertEq(TestERC20(token1).balanceOf(address(this)), currBalance1 - 100);

        assertEq(UniswapV4ERC20(fullRange.poolToERC20(id)).balanceOf(address(this)), 100);
    }

    function testInitialAddLiquidityWithFeeSucceeds() public {
        manager.initialize(feeKey, SQRT_RATIO_1_1);

        uint256 currBalance0 = TestERC20(token0).balanceOf(address(this));
        uint256 currBalance1 = TestERC20(token1).balanceOf(address(this));

        fullRange.addLiquidity(address(token0), address(token1), 3000, 100, 100, address(this), 12329839823);

        assertEq(TestERC20(token0).balanceOf(address(this)), currBalance0 - 100);
        assertEq(TestERC20(token1).balanceOf(address(this)), currBalance1 - 100);

        assertEq(UniswapV4ERC20(fullRange.poolToERC20(feeId)).balanceOf(address(this)), 100);

        // check pool position state
        (
            uint128 liquidity,
            uint256 feeGrowthInside0LastX128,
            uint256 feeGrowthInside1LastX128,
            uint128 tokensOwed0,
            uint128 tokensOwed1
        ) = fullRange.poolToHookPosition(feeId);

        assertEq(liquidity, 100);
        // TODO: make sure 0 is correct
        assertEq(feeGrowthInside0LastX128, 0);
        assertEq(feeGrowthInside1LastX128, 0);
        assertEq(tokensOwed0, 0);
        assertEq(tokensOwed1, 0);
    }

    function testAddLiquidityFailsIfNoPool() public {
        // PoolNotInitialized()
        vm.expectRevert(0x486aa307);
        fullRange.addLiquidity(address(token0), address(token1), 0, 100, 100, address(this), 12329839823);
    }

    function testAddLiquiditySucceedsWithNoFee() public {
        manager.initialize(key, SQRT_RATIO_1_1);

        uint256 currBalance0 = TestERC20(token0).balanceOf(address(this));
        uint256 currBalance1 = TestERC20(token1).balanceOf(address(this));

        fullRange.addLiquidity(address(token0), address(token1), 0, 100, 100, address(this), 12329839823);

        assertEq(UniswapV4ERC20(fullRange.poolToERC20(id)).balanceOf(address(this)), 100);

        fullRange.addLiquidity(address(token0), address(token1), 0, 50, 50, address(this), 12329839823);

        assertEq(TestERC20(token0).balanceOf(address(this)), currBalance0 - 150);
        assertEq(TestERC20(token1).balanceOf(address(this)), currBalance1 - 150);

        assertEq(UniswapV4ERC20(fullRange.poolToERC20(id)).balanceOf(address(this)), 150);
    }

    function testAddLiquiditySucceedsWithFee() public {
        manager.initialize(feeKey, SQRT_RATIO_1_1);

        uint256 currBalance0 = TestERC20(token0).balanceOf(address(this));
        uint256 currBalance1 = TestERC20(token1).balanceOf(address(this));

        fullRange.addLiquidity(address(token0), address(token1), 3000, 100, 100, address(this), 12329839823);

        assertEq(UniswapV4ERC20(fullRange.poolToERC20(feeId)).balanceOf(address(this)), 100);

        fullRange.addLiquidity(address(token0), address(token1), 3000, 50, 50, address(this), 12329839823);

        assertEq(TestERC20(token0).balanceOf(address(this)), currBalance0 - 150);
        assertEq(TestERC20(token1).balanceOf(address(this)), currBalance1 - 150);

        assertEq(UniswapV4ERC20(fullRange.poolToERC20(feeId)).balanceOf(address(this)), 150);

        // check pool position state
        (
            uint128 liquidity,
            uint256 feeGrowthInside0LastX128,
            uint256 feeGrowthInside1LastX128,
            uint128 tokensOwed0,
            uint128 tokensOwed1
        ) = fullRange.poolToHookPosition(feeId);

        assertEq(liquidity, 150);
        // TODO: make sure 0 is correct
        assertEq(feeGrowthInside0LastX128, 0);
        assertEq(feeGrowthInside1LastX128, 0);
        assertEq(tokensOwed0, 0);
        assertEq(tokensOwed1, 0);
    }

    function testAddLiquidityWithDiffRatiosAndNoFee() public {
        manager.initialize(key, SQRT_RATIO_1_1);

        uint256 currBalance0 = TestERC20(token0).balanceOf(address(this));
        uint256 currBalance1 = TestERC20(token1).balanceOf(address(this));

        fullRange.addLiquidity(address(token0), address(token1), 0, 100, 100, address(this), 12329839823);

        assertEq(UniswapV4ERC20(fullRange.poolToERC20(id)).balanceOf(address(this)), 100);

        fullRange.addLiquidity(address(token0), address(token1), 0, 50, 25, address(this), 12329839823);

        // even though we desire to deposit more token0, we cannot, since the ratio is 1:1
        assertEq(TestERC20(token0).balanceOf(address(this)), currBalance0 - 125);
        assertEq(TestERC20(token1).balanceOf(address(this)), currBalance1 - 125);

        assertEq(UniswapV4ERC20(fullRange.poolToERC20(id)).balanceOf(address(this)), 125);
    }

    function testAddLiquidityWithDiffRatiosAndFee() public {
        manager.initialize(feeKey, SQRT_RATIO_1_1);

        uint256 currBalance0 = TestERC20(token0).balanceOf(address(this));
        uint256 currBalance1 = TestERC20(token1).balanceOf(address(this));

        fullRange.addLiquidity(address(token0), address(token1), 3000, 100, 100, address(this), 12329839823);

        assertEq(UniswapV4ERC20(fullRange.poolToERC20(feeId)).balanceOf(address(this)), 100);

        fullRange.addLiquidity(address(token0), address(token1), 3000, 50, 25, address(this), 12329839823);

        // evem though we desire to deposit more token0, we cannot, since the ratio is 1:1
        assertEq(TestERC20(token0).balanceOf(address(this)), currBalance0 - 125);
        assertEq(TestERC20(token1).balanceOf(address(this)), currBalance1 - 125);

        assertEq(UniswapV4ERC20(fullRange.poolToERC20(feeId)).balanceOf(address(this)), 125);

        // check pool position state
        (
            uint128 liquidity,
            uint256 feeGrowthInside0LastX128,
            uint256 feeGrowthInside1LastX128,
            uint128 tokensOwed0,
            uint128 tokensOwed1
        ) = fullRange.poolToHookPosition(feeId);

        assertEq(liquidity, 125);
        // TODO: make sure 0 is correct
        assertEq(feeGrowthInside0LastX128, 0);
        assertEq(feeGrowthInside1LastX128, 0);
        assertEq(tokensOwed0, 0);
        assertEq(tokensOwed1, 0);
    }

    // TODO: make sure these numbers work -- im so confused lmao
    function testSwapAddLiquiditySucceedsWithNoFee() public {
        manager.initialize(key, SQRT_RATIO_1_1);

        uint256 currBalance0 = TestERC20(token0).balanceOf(address(this));
        uint256 currBalance1 = TestERC20(token1).balanceOf(address(this));

        fullRange.addLiquidity(
            address(token0), address(token1), 0, 1000000000000000000, 1000000000000000000, address(this), 12329839823
        );

        assertEq(UniswapV4ERC20(fullRange.poolToERC20(id)).balanceOf(address(this)), 1000000000000000000);
        assertEq(TestERC20(token0).balanceOf(address(this)), currBalance0 - 1000000000000000000);
        assertEq(TestERC20(token0).balanceOf(address(this)), currBalance0 - 1000000000000000000);

        IPoolManager.SwapParams memory params =
            IPoolManager.SwapParams({zeroForOne: true, amountSpecified: 100, sqrtPriceLimitX96: SQRT_RATIO_1_2});

        PoolSwapTest.TestSettings memory testSettings =
            PoolSwapTest.TestSettings({withdrawTokens: true, settleUsingTransfer: true});

        vm.expectEmit(true, true, true, true);
        emit Swap(id, address(swapRouter), 100, -99, 79228162514264329670727698910, 1000000000000000000, -1, 0); // TODO: modify this emit

        swapRouter.swap(key, params, testSettings);

        assertEq(TestERC20(token0).balanceOf(address(this)), currBalance0 - 1000000000000000000 - 100);
        assertEq(TestERC20(token1).balanceOf(address(this)), currBalance1 - 1000000000000000000 + 99);

        fullRange.addLiquidity(address(token0), address(token1), 0, 50, 50, address(this), 12329839823);

        assertEq(TestERC20(token0).balanceOf(address(this)), currBalance0 - 1000000000000000000 - 100 - 50);
        assertEq(TestERC20(token1).balanceOf(address(this)), currBalance1 - 1000000000000000000 + 99 - 49);

        // managed to provide 49 liquidity due to change in ratio
        assertEq(UniswapV4ERC20(fullRange.poolToERC20(id)).balanceOf(address(this)), 1000000000000000049);
    }

    function testSwapAddLiquiditySucceedsWithFeeNoRebalance() public {
        manager.initialize(feeKey, SQRT_RATIO_1_1);

        uint256 currBalance0 = TestERC20(token0).balanceOf(address(this));
        uint256 currBalance1 = TestERC20(token1).balanceOf(address(this));

        fullRange.addLiquidity(
            address(token0), address(token1), 3000, 1000000000000000000, 1000000000000000000, address(this), 12329839823
        );

        assertEq(UniswapV4ERC20(fullRange.poolToERC20(feeId)).balanceOf(address(this)), 1000000000000000000);
        assertEq(TestERC20(token0).balanceOf(address(this)), currBalance0 - 1000000000000000000);
        assertEq(TestERC20(token0).balanceOf(address(this)), currBalance0 - 1000000000000000000);

        IPoolManager.SwapParams memory params =
            IPoolManager.SwapParams({zeroForOne: true, amountSpecified: 100, sqrtPriceLimitX96: SQRT_RATIO_1_2});

        PoolSwapTest.TestSettings memory testSettings =
            PoolSwapTest.TestSettings({withdrawTokens: true, settleUsingTransfer: true});

        // only get 98 back because of fees
        vm.expectEmit(true, true, true, true);
        emit Swap(feeId, address(swapRouter), 100, -98, 79228162514264329749955861424, 1000000000000000000, -1, 3000); // TODO: modify this emit

        swapRouter.swap(feeKey, params, testSettings);

        uint256 feeGrowthInside0LastX128test =
                manager.getPosition(feeId, address(fullRange), MIN_TICK, MAX_TICK).feeGrowthInside0LastX128;
        uint256 feeGrowthInside1LastX128test =
                manager.getPosition(feeId, address(fullRange), MIN_TICK, MAX_TICK).feeGrowthInside1LastX128;
        console.log("post swap, fee growth should increase");
        console.log(feeGrowthInside0LastX128test);
        console.log(feeGrowthInside1LastX128test);

        assertEq(TestERC20(token0).balanceOf(address(this)), currBalance0 - 1000000000000000000 - 100);
        assertEq(TestERC20(token1).balanceOf(address(this)), currBalance1 - 1000000000000000000 + 98);

        // check pool position state
        (
            uint128 prevLiquidity,
            uint256 prevFeeGrowthInside0LastX128,
            uint256 prevFeeGrowthInside1LastX128,
            uint128 prevTokensOwed0,
            uint128 prevTokensOwed1
        ) = fullRange.poolToHookPosition(feeId);

        assertEq(prevLiquidity, 1000000000000000000);
        assertEq(prevFeeGrowthInside0LastX128, 0);
        assertEq(prevFeeGrowthInside1LastX128, 0);
        assertEq(prevTokensOwed0, 0);
        assertEq(prevTokensOwed1, 0);

        // all of the fee updates should have happened here
        fullRange.addLiquidity(address(token0), address(token1), 3000, 50, 50, address(this), 12329839823);

        assertEq(TestERC20(token0).balanceOf(address(this)), currBalance0 - 1000000000000000000 - 100 - 50);
        assertEq(TestERC20(token1).balanceOf(address(this)), currBalance1 - 1000000000000000000 + 98 - 49);

        // managed to provide 49 liquidity due to change in ratio
        assertEq(UniswapV4ERC20(fullRange.poolToERC20(feeId)).balanceOf(address(this)), 1000000000000000049);

        // check pool position state
        (
            uint128 liquidity,
            uint256 feeGrowthInside0LastX128,
            uint256 feeGrowthInside1LastX128,
            uint128 tokensOwed0,
            uint128 tokensOwed1
        ) = fullRange.poolToHookPosition(feeId);

        assertEq(liquidity, 1000000000000000049);

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

    // TODO: rewrite this
    function testSwapAddLiquiditySucceedsWithFeeRebalance() public {
        vm.roll(100);
        manager.initialize(feeKey, SQRT_RATIO_1_1);

        uint256 currBalance0 = TestERC20(token0).balanceOf(address(this));
        uint256 currBalance1 = TestERC20(token1).balanceOf(address(this));

        fullRange.addLiquidity(address(token0), address(token1), 3000, 1 ether, 1 ether, address(this), 12329839823);

        assertEq(UniswapV4ERC20(fullRange.poolToERC20(feeId)).balanceOf(address(this)), 1 ether);

        IPoolManager.SwapParams memory params =
            IPoolManager.SwapParams({zeroForOne: true, amountSpecified: 10000000, sqrtPriceLimitX96: SQRT_RATIO_1_2});

        PoolSwapTest.TestSettings memory testSettings =
            PoolSwapTest.TestSettings({withdrawTokens: true, settleUsingTransfer: true});

        swapRouter.swap(feeKey, params, testSettings);

        // check pool position state
        (
            uint128 liquidity,
            uint256 feeGrowthInside0LastX128,
            uint256 feeGrowthInside1LastX128,
            uint128 tokensOwed0,
            uint128 tokensOwed1
        ) = fullRange.poolToHookPosition(feeId);

        assertEq(liquidity, 1 ether);
        assertEq(feeGrowthInside0LastX128, 0);
        assertEq(feeGrowthInside1LastX128, 0);
        assertEq(tokensOwed0, 0);
        assertEq(tokensOwed1, 0);

        fullRange.addLiquidity(address(token0), address(token1), 3000, 50, 50, address(this), 12329839823);
        
        // all the core fee updates should have happened by now

        vm.roll(101);

        vm.breakpoint("g");

        // rebalance should happen before this
        fullRange.addLiquidity(address(token0), address(token1), 3000, 50, 50, address(this), 12329839823);

        // // check pool position state
        // (
        //     liquidity,
        //     feeGrowthInside0LastX128,
        //     feeGrowthInside1LastX128,
        //     tokensOwed0,
        //     tokensOwed1
        // ) = fullRange.poolToHookPosition(feeId);

        // assertEq(liquidity, 135);

        // // TODO: calculate the feeGrowth on my own after a swap
        // Position.Info memory posInfo = manager.getPosition(feeId, address(fullRange), MIN_TICK, MAX_TICK);

        // assertEq(feeGrowthInside0LastX128, posInfo.feeGrowthInside0LastX128);
        // assertEq(feeGrowthInside1LastX128, posInfo.feeGrowthInside1LastX128);

        // // TODO: calculate the tokens owed on my own after a swap
        // assertEq(tokensOwed0, 0);
        // assertEq(tokensOwed1, 0);
    }

    function testInitialRemoveLiquiditySucceeds() public {
        manager.initialize(key, SQRT_RATIO_1_1);

        uint256 currBalance0 = TestERC20(token0).balanceOf(address(this));
        uint256 currBalance1 = TestERC20(token1).balanceOf(address(this));

        fullRange.addLiquidity(address(token0), address(token1), 0, 100, 100, address(this), 12329839823);

        assertEq(UniswapV4ERC20(fullRange.poolToERC20(id)).balanceOf(address(this)), 100);

        assertEq(TestERC20(token0).balanceOf(address(this)), currBalance0 - 100);
        assertEq(TestERC20(token1).balanceOf(address(this)), currBalance1 - 100);

        // approve fullRange to spend our liquidity tokens
        UniswapV4ERC20(fullRange.poolToERC20(id)).approve(address(fullRange), type(uint256).max);

        fullRange.removeLiquidity(address(token0), address(token1), 0, 100, 0, 0, address(this), 12329839823);

        assertEq(UniswapV4ERC20(fullRange.poolToERC20(id)).balanceOf(address(this)), 0);
        assertEq(TestERC20(token0).balanceOf(address(this)), currBalance0 - 1);
        assertEq(TestERC20(token1).balanceOf(address(this)), currBalance1 - 1);
    }

    function testRemoveLiquidityFailsIfNoPool() public {
        // PoolNotInitialized()
        vm.expectRevert(0x486aa307);
        fullRange.addLiquidity(address(token0), address(token1), 0, 100, 100, address(this), 12329839823);
    }

    function testRemoveLiquiditySucceedsWithNoFee() public {
        manager.initialize(key, SQRT_RATIO_1_1);

        uint256 currBalance0 = TestERC20(token0).balanceOf(address(this));
        uint256 currBalance1 = TestERC20(token1).balanceOf(address(this));

        fullRange.addLiquidity(address(token0), address(token1), 0, 100, 100, address(this), 12329839823);

        assertEq(TestERC20(token0).balanceOf(address(this)), currBalance0 - 100);
        assertEq(TestERC20(token1).balanceOf(address(this)), currBalance1 - 100);

        assertEq(UniswapV4ERC20(fullRange.poolToERC20(id)).balanceOf(address(this)), 100);

        fullRange.addLiquidity(address(token0), address(token1), 0, 50, 50, address(this), 12329839823);

        assertEq(TestERC20(token0).balanceOf(address(this)), currBalance0 - 150);
        assertEq(TestERC20(token1).balanceOf(address(this)), currBalance1 - 150);

        assertEq(UniswapV4ERC20(fullRange.poolToERC20(id)).balanceOf(address(this)), 150);

        UniswapV4ERC20(fullRange.poolToERC20(id)).approve(address(fullRange), type(uint256).max);

        fullRange.removeLiquidity(address(token0), address(token1), 0, 150, 0, 0, address(this), 12329839823);

        assertEq(UniswapV4ERC20(fullRange.poolToERC20(id)).balanceOf(address(this)), 0);
        assertEq(TestERC20(token0).balanceOf(address(this)), currBalance0 - 1);
        assertEq(TestERC20(token1).balanceOf(address(this)), currBalance1 - 1);
    }

    function testRemoveLiquiditySucceedsWithPartial() public {
        manager.initialize(key, SQRT_RATIO_1_1);

        uint256 currBalance0 = TestERC20(token0).balanceOf(address(this));
        uint256 currBalance1 = TestERC20(token1).balanceOf(address(this));

        fullRange.addLiquidity(address(token0), address(token1), 0, 100, 100, address(this), 12329839823);

        assertEq(UniswapV4ERC20(fullRange.poolToERC20(id)).balanceOf(address(this)), 100);

        assertEq(TestERC20(token0).balanceOf(address(this)), currBalance0 - 100);
        assertEq(TestERC20(token1).balanceOf(address(this)), currBalance1 - 100);

        UniswapV4ERC20(fullRange.poolToERC20(id)).approve(address(fullRange), type(uint256).max);

        fullRange.removeLiquidity(address(token0), address(token1), 0, 50, 0, 0, address(this), 12329839823);

        assertEq(UniswapV4ERC20(fullRange.poolToERC20(id)).balanceOf(address(this)), 50);
        assertEq(TestERC20(token0).balanceOf(address(this)), currBalance0 - 51);
        assertEq(TestERC20(token1).balanceOf(address(this)), currBalance1 - 51);
    }

    function testRemoveLiquidityWithDiffRatiosAndNoFee() public {
        manager.initialize(key, SQRT_RATIO_1_1);

        uint256 currBalance0 = TestERC20(token0).balanceOf(address(this));
        uint256 currBalance1 = TestERC20(token1).balanceOf(address(this));

        fullRange.addLiquidity(address(token0), address(token1), 0, 100, 100, address(this), 12329839823);

        assertEq(TestERC20(token0).balanceOf(address(this)), currBalance0 - 100);
        assertEq(TestERC20(token1).balanceOf(address(this)), currBalance1 - 100);

        assertEq(UniswapV4ERC20(fullRange.poolToERC20(id)).balanceOf(address(this)), 100);

        fullRange.addLiquidity(address(token0), address(token1), 0, 50, 25, address(this), 12329839823);

        assertEq(TestERC20(token0).balanceOf(address(this)), currBalance0 - 125);
        assertEq(TestERC20(token1).balanceOf(address(this)), currBalance1 - 125);

        assertEq(UniswapV4ERC20(fullRange.poolToERC20(id)).balanceOf(address(this)), 125);

        UniswapV4ERC20(fullRange.poolToERC20(id)).approve(address(fullRange), type(uint256).max);

        fullRange.removeLiquidity(address(token0), address(token1), 0, 50, 0, 0, address(this), 12329839823);

        // TODO: balance checks for token0 and token1
        assertEq(TestERC20(token0).balanceOf(address(this)), currBalance0 - 76);
        assertEq(TestERC20(token1).balanceOf(address(this)), currBalance1 - 76);

        assertEq(UniswapV4ERC20(fullRange.poolToERC20(id)).balanceOf(address(this)), 75);
    }

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
