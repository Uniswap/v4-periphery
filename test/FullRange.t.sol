// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {Test} from "forge-std/Test.sol";
import {GasSnapshot} from "forge-gas-snapshot/GasSnapshot.sol";
import {Hooks} from "@uniswap/v4-core/contracts/libraries/Hooks.sol";
import {Position} from "@uniswap/v4-core/contracts/libraries/Position.sol";
import {FullRange} from "../contracts/hooks/examples/FullRange.sol";
import {FullRangeImplementation} from "./shared/implementation/FullRangeImplementation.sol";
import {PoolManager} from "@uniswap/v4-core/contracts/PoolManager.sol";
import {IPoolManager} from "@uniswap/v4-core/contracts/interfaces/IPoolManager.sol";
import {Deployers} from "@uniswap/v4-core/test/foundry-tests/utils/Deployers.sol";
import {TestERC20} from "@uniswap/v4-core/contracts/test/TestERC20.sol";
import {CurrencyLibrary, Currency} from "@uniswap/v4-core/contracts/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/contracts/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/contracts/types/PoolKey.sol";
import {PoolModifyPositionTest} from "@uniswap/v4-core/contracts/test/PoolModifyPositionTest.sol";
import {PoolSwapTest} from "@uniswap/v4-core/contracts/test/PoolSwapTest.sol";
import {TickMath} from "@uniswap/v4-core/contracts/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v4-core/contracts/libraries/FullMath.sol";
import {IHooks} from "@uniswap/v4-core/contracts/interfaces/IHooks.sol";
import {UniswapV4ERC20} from "../contracts/libraries/UniswapV4ERC20.sol";
import {FixedPoint128} from "@uniswap/v4-core/contracts/libraries/FixedPoint128.sol";
import {BalanceDelta} from "@uniswap/v4-core/contracts/types/BalanceDelta.sol";

import "forge-std/console.sol";

contract TestFullRange is Test, Deployers, GasSnapshot {
    using PoolIdLibrary for PoolKey;

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
    PoolKey key;
    PoolId id;

    // the key that includes a pool fee for pool fee rebalance tests
    PoolKey feeKey;
    PoolId feeId;

    PoolKey feeKey2;
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
        vm.etch(address(fullRange), address(impl).code);
        key = PoolKey(Currency.wrap(address(token0)), Currency.wrap(address(token1)), 0, TICK_SPACING, fullRange);
        id = key.toId();

        feeKey = PoolKey(Currency.wrap(address(token0)), Currency.wrap(address(token1)), 3000, TICK_SPACING, fullRange);
        feeId = feeKey.toId();

        feeKey2 = PoolKey(Currency.wrap(address(token1)), Currency.wrap(address(token2)), 3000, TICK_SPACING, fullRange);
        feeId2 = feeKey.toId();

        modifyPositionRouter = new PoolModifyPositionTest(manager);
        swapRouter = new PoolSwapTest(manager);

        token0.approve(address(fullRange), type(uint256).max);
        token1.approve(address(fullRange), type(uint256).max);
        token2.approve(address(fullRange), type(uint256).max);
        token0.approve(address(modifyPositionRouter), type(uint256).max);
        token1.approve(address(modifyPositionRouter), type(uint256).max);
        token2.approve(address(modifyPositionRouter), type(uint256).max);
        token0.approve(address(swapRouter), type(uint256).max);
        token1.approve(address(swapRouter), type(uint256).max);
        token2.approve(address(swapRouter), type(uint256).max);
        token0.approve(address(manager), type(uint256).max);
        token1.approve(address(manager), type(uint256).max);
        token2.approve(address(manager), type(uint256).max);
    }

    function testBeforeInitializeAllowsPoolCreation() public {
        vm.expectEmit(true, true, true, true);
        emit Initialize(feeId, feeKey.currency0, feeKey.currency1, feeKey.fee, feeKey.tickSpacing, feeKey.hooks);
        snapStart("initialize with fee");
        manager.initialize(feeKey, SQRT_RATIO_1_1);
        snapEnd();

        (,, address liquidityToken) = fullRange.poolInfo(feeId);

        assertFalse(liquidityToken == address(0));
    }

    function testBeforeInitializeRevertsIfWrongSpacing() public {
        PoolKey memory wrongKey =
            PoolKey(Currency.wrap(address(token0)), Currency.wrap(address(token1)), 0, TICK_SPACING + 1, fullRange);

        vm.expectRevert("Tick spacing must be default");
        manager.initialize(wrongKey, SQRT_RATIO_1_1);
    }

    function testInitialAddLiquiditySucceeds() public {
        manager.initialize(feeKey, SQRT_RATIO_1_1);

        uint256 prevBalance0 = TestERC20(token0).balanceOf(address(this));
        uint256 prevBalance1 = TestERC20(token1).balanceOf(address(this));

        snapStart("add liquidity with fee");
        fullRange.addLiquidity(address(token0), address(token1), 3000, 10 ether, 10 ether, address(this), MAX_DEADLINE);
        snapEnd();

        assertEq(TestERC20(token0).balanceOf(address(this)), prevBalance0 - 10 ether);
        assertEq(TestERC20(token1).balanceOf(address(this)), prevBalance1 - 10 ether);

        (,, address liquidityToken) = fullRange.poolInfo(feeId);

        assertEq(UniswapV4ERC20(liquidityToken).balanceOf(address(this)), 10 ether);

        (uint128 liquidity, bool owed,) = fullRange.poolInfo(feeId);

        assertEq(liquidity, 10 ether);
        assertEq(owed, false);
    }

    function testAddLiquidityFailsIfNoPool() public {
        vm.expectRevert(FullRange.PoolNotInitialized.selector);
        fullRange.addLiquidity(address(token0), address(token1), 0, 10 ether, 10 ether, address(this), MAX_DEADLINE);
    }

    function testAddLiquidityWithDiffRatios() public {
        manager.initialize(feeKey, SQRT_RATIO_1_1);

        uint256 prevBalance0 = TestERC20(token0).balanceOf(address(this));
        uint256 prevBalance1 = TestERC20(token1).balanceOf(address(this));

        fullRange.addLiquidity(address(token0), address(token1), 3000, 50 ether, 25 ether, address(this), MAX_DEADLINE);

        assertEq(TestERC20(token0).balanceOf(address(this)), prevBalance0 - 25 ether);
        assertEq(TestERC20(token1).balanceOf(address(this)), prevBalance1 - 25 ether);

        (,, address liquidityToken) = fullRange.poolInfo(feeId);

        assertEq(UniswapV4ERC20(liquidityToken).balanceOf(address(this)), 25 ether + 1);

        (uint128 liquidity, bool owed,) = fullRange.poolInfo(feeId);

        assertEq(liquidity, 25 ether + 1);
        assertEq(owed, false);
    }

    // TODO: check fees accumulated ?
    function testSwapAddLiquiditySucceeds() public {
        manager.initialize(feeKey, SQRT_RATIO_1_1);

        uint256 prevBalance0 = TestERC20(token0).balanceOf(address(this));
        uint256 prevBalance1 = TestERC20(token1).balanceOf(address(this));

        fullRange.addLiquidity(address(token0), address(token1), 3000, 10 ether, 10 ether, address(this), MAX_DEADLINE);

        (,, address liquidityToken) = fullRange.poolInfo(feeId);

        assertEq(UniswapV4ERC20(liquidityToken).balanceOf(address(this)), 10 ether);
        assertEq(TestERC20(token0).balanceOf(address(this)), prevBalance0 - 10 ether);
        assertEq(TestERC20(token0).balanceOf(address(this)), prevBalance1 - 10 ether);

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

        assertEq(TestERC20(token0).balanceOf(address(this)), prevBalance0 - 10 ether - 1 ether);
        assertEq(TestERC20(token1).balanceOf(address(this)), prevBalance1 - 9093389106119850869);

        // check pool position state
        (uint128 prevLiquidity, bool prevOwed,) = fullRange.poolInfo(feeId);

        assertEq(prevLiquidity, 10 ether);
        assertEq(prevOwed, true);

        // all of the fee updates should have happened here
        snapStart("add liquidity with fee accumulated");
        fullRange.addLiquidity(address(token0), address(token1), 3000, 5 ether, 5 ether, address(this), MAX_DEADLINE);
        snapEnd();

        assertEq(UniswapV4ERC20(liquidityToken).balanceOf(address(this)), 14546694553059925434);

        // check pool position state
        (uint128 liquidity, bool owed,) = fullRange.poolInfo(feeId);

        assertEq(liquidity, 14546694553059925434);
        assertEq(owed, true);
    }

    function testSwapAddLiquidityTwoPoolsAndNoRebalance() public {
        manager.initialize(feeKey, SQRT_RATIO_1_1);
        manager.initialize(feeKey2, SQRT_RATIO_1_1);

        fullRange.addLiquidity(address(token0), address(token1), 3000, 10 ether, 10 ether, address(this), MAX_DEADLINE);
        fullRange.addLiquidity(address(token1), address(token2), 3000, 10 ether, 10 ether, address(this), MAX_DEADLINE);

        IPoolManager.SwapParams memory params =
            IPoolManager.SwapParams({zeroForOne: true, amountSpecified: 10000000, sqrtPriceLimitX96: SQRT_RATIO_1_2});

        PoolSwapTest.TestSettings memory testSettings =
            PoolSwapTest.TestSettings({withdrawTokens: true, settleUsingTransfer: true});

        swapRouter.swap(feeKey, params, testSettings);
        swapRouter.swap(feeKey2, params, testSettings);

        // check pool position state
        (uint128 liquidity, bool owed,) = fullRange.poolInfo(feeId);

        assertEq(liquidity, 10000000000000000000);

        assertEq(owed, true);

        (liquidity, owed,) = fullRange.poolInfo(feeId2);

        assertEq(liquidity, 10000000000000000000);
        assertEq(owed, true);
    }

    function testInitialRemoveLiquiditySucceedsNoFee() public {
        manager.initialize(key, SQRT_RATIO_1_1);

        uint256 prevBalance0 = TestERC20(token0).balanceOf(address(this));
        uint256 prevBalance1 = TestERC20(token1).balanceOf(address(this));

        fullRange.addLiquidity(address(token0), address(token1), 0, 10 ether, 10 ether, address(this), MAX_DEADLINE);

        (,, address liquidityToken) = fullRange.poolInfo(id);

        assertEq(UniswapV4ERC20(liquidityToken).balanceOf(address(this)), 10 ether);

        assertEq(TestERC20(token0).balanceOf(address(this)), prevBalance0 - 10 ether);
        assertEq(TestERC20(token1).balanceOf(address(this)), prevBalance1 - 10 ether);

        // approve fullRange to spend our liquidity tokens
        UniswapV4ERC20(liquidityToken).approve(address(fullRange), type(uint256).max);

        snapStart("remove liquidity no fee");
        fullRange.removeLiquidity(address(token0), address(token1), 0, 1 ether, MAX_DEADLINE);
        snapEnd();

        assertEq(UniswapV4ERC20(liquidityToken).balanceOf(address(this)), 9 ether);
        assertEq(TestERC20(token0).balanceOf(address(this)), prevBalance0 - 10 ether + 1 ether - 1);
        assertEq(TestERC20(token1).balanceOf(address(this)), prevBalance1 - 10 ether + 1 ether - 1);
    }

    function testInitialRemoveLiquiditySucceedsWithFee() public {
        manager.initialize(feeKey, SQRT_RATIO_1_1);

        uint256 prevBalance0 = TestERC20(token0).balanceOf(address(this));
        uint256 prevBalance1 = TestERC20(token1).balanceOf(address(this));

        fullRange.addLiquidity(address(token0), address(token1), 3000, 10 ether, 10 ether, address(this), MAX_DEADLINE);

        (,, address liquidityToken) = fullRange.poolInfo(feeId);

        assertEq(UniswapV4ERC20(liquidityToken).balanceOf(address(this)), 10 ether);

        assertEq(TestERC20(token0).balanceOf(address(this)), prevBalance0 - 10 ether);
        assertEq(TestERC20(token1).balanceOf(address(this)), prevBalance1 - 10 ether);

        // approve fullRange to spend our liquidity tokens
        UniswapV4ERC20(liquidityToken).approve(address(fullRange), type(uint256).max);

        snapStart("remove liquidity with fee");
        fullRange.removeLiquidity(address(token0), address(token1), 3000, 1 ether, MAX_DEADLINE);
        snapEnd();

        assertEq(UniswapV4ERC20(liquidityToken).balanceOf(address(this)), 9 ether);
        assertEq(TestERC20(token0).balanceOf(address(this)), prevBalance0 - 9 ether - 1);
        assertEq(TestERC20(token1).balanceOf(address(this)), prevBalance1 - 9 ether - 1);

        (uint128 liquidity, bool owed,) = fullRange.poolInfo(feeId);

        assertEq(liquidity, 9 ether);
        assertEq(owed, false);
    }

    function testRemoveLiquidityFailsIfNoPool() public {
        vm.expectRevert(FullRange.PoolNotInitialized.selector);
        fullRange.addLiquidity(address(token0), address(token1), 0, 10 ether, 10 ether, address(this), MAX_DEADLINE);
    }

    function testRemoveLiquiditySucceedsWithPartialAndFee() public {
        manager.initialize(feeKey, SQRT_RATIO_1_1);

        uint256 prevBalance0 = TestERC20(token0).balanceOf(address(this));
        uint256 prevBalance1 = TestERC20(token1).balanceOf(address(this));

        fullRange.addLiquidity(address(token0), address(token1), 3000, 10 ether, 10 ether, address(this), MAX_DEADLINE);

        (,, address liquidityToken) = fullRange.poolInfo(feeId);

        assertEq(UniswapV4ERC20(liquidityToken).balanceOf(address(this)), 10 ether);

        assertEq(TestERC20(token0).balanceOf(address(this)), prevBalance0 - 10 ether);
        assertEq(TestERC20(token1).balanceOf(address(this)), prevBalance1 - 10 ether);

        UniswapV4ERC20(liquidityToken).approve(address(fullRange), type(uint256).max);

        fullRange.removeLiquidity(address(token0), address(token1), 3000, 5 ether, MAX_DEADLINE);

        assertEq(UniswapV4ERC20(liquidityToken).balanceOf(address(this)), 5 ether);
        assertEq(TestERC20(token0).balanceOf(address(this)), prevBalance0 - 5 ether - 1);
        assertEq(TestERC20(token1).balanceOf(address(this)), prevBalance1 - 5 ether - 1);

        (uint128 liquidity, bool owed,) = fullRange.poolInfo(feeId);

        assertEq(liquidity, 5 ether);
        assertEq(owed, false);
    }

    function testRemoveLiquidityWithDiffRatiosAndFee() public {
        manager.initialize(feeKey, SQRT_RATIO_1_1);

        uint256 prevBalance0 = TestERC20(token0).balanceOf(address(this));
        uint256 prevBalance1 = TestERC20(token1).balanceOf(address(this));

        fullRange.addLiquidity(address(token0), address(token1), 3000, 10 ether, 10 ether, address(this), MAX_DEADLINE);

        assertEq(TestERC20(token0).balanceOf(address(this)), prevBalance0 - 10 ether);
        assertEq(TestERC20(token1).balanceOf(address(this)), prevBalance1 - 10 ether);

        (,, address liquidityToken) = fullRange.poolInfo(feeId);

        assertEq(UniswapV4ERC20(liquidityToken).balanceOf(address(this)), 10 ether);

        fullRange.addLiquidity(address(token0), address(token1), 3000, 5 ether, 2.5 ether, address(this), MAX_DEADLINE);

        assertEq(TestERC20(token0).balanceOf(address(this)), prevBalance0 - 12.5 ether);
        assertEq(TestERC20(token1).balanceOf(address(this)), prevBalance1 - 12.5 ether);

        assertEq(UniswapV4ERC20(liquidityToken).balanceOf(address(this)), 12.5 ether);

        UniswapV4ERC20(liquidityToken).approve(address(fullRange), type(uint256).max);

        fullRange.removeLiquidity(address(token0), address(token1), 3000, 5 ether, MAX_DEADLINE);

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

        (,, address liquidityToken) = fullRange.poolInfo(feeId);

        UniswapV4ERC20(liquidityToken).approve(address(fullRange), type(uint256).max);

        snapStart("remove liquidity with fee no rebalance");
        fullRange.removeLiquidity(address(token0), address(token1), 3000, 5 ether, MAX_DEADLINE);
        snapEnd();

        assertEq(TestERC20(token0).balanceOf(address(this)), prevBalance0 - 5500750051143335487);
        assertEq(TestERC20(token1).balanceOf(address(this)), prevBalance1 - 4547314599141369503);

        assertEq(UniswapV4ERC20(liquidityToken).balanceOf(address(this)), 5 ether);

        (uint128 liquidity, bool owed,) = fullRange.poolInfo(feeId);

        assertEq(liquidity, 5 ether);
        assertEq(owed, false);
    }

    function testSwapRemoveLiquiditySucceedsWithFeeRebalance() public {
        manager.initialize(feeKey, SQRT_RATIO_1_1);

        fullRange.addLiquidity(address(token0), address(token1), 3000, 10 ether, 10 ether, address(this), MAX_DEADLINE);

        (,, address liquidityToken) = fullRange.poolInfo(feeId);

        assertEq(UniswapV4ERC20(liquidityToken).balanceOf(address(this)), 10 ether);

        IPoolManager.SwapParams memory params =
            IPoolManager.SwapParams({zeroForOne: true, amountSpecified: 1 ether, sqrtPriceLimitX96: SQRT_RATIO_1_2});

        PoolSwapTest.TestSettings memory testSettings =
            PoolSwapTest.TestSettings({withdrawTokens: true, settleUsingTransfer: true});

        swapRouter.swap(feeKey, params, testSettings);

        fullRange.addLiquidity(address(token0), address(token1), 3000, 5 ether, 5 ether, address(this), MAX_DEADLINE);

        UniswapV4ERC20(liquidityToken).approve(address(fullRange), type(uint256).max);

        snapStart("remove liquidity with fee and rebalance");
        fullRange.removeLiquidity(address(token0), address(token1), 3000, 5 ether, MAX_DEADLINE);
        snapEnd();

        (uint128 liquidity, bool owed,) = fullRange.poolInfo(feeId);
        assertEq(liquidity, 9546694553059925434);

        assertEq(owed, false);
    }

    function testBeforeModifyPositionFailsWithWrongMsgSender() public {
        manager.initialize(key, SQRT_RATIO_1_1);

        vm.expectRevert("sender must be hook");

        modifyPositionRouter.modifyPosition(
            key, IPoolManager.ModifyPositionParams({tickLower: MIN_TICK, tickUpper: MAX_TICK, liquidityDelta: 100})
        );
    }
}
