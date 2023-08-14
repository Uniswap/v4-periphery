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
import {MockERC20} from "@uniswap/v4-core/test/foundry-tests/utils/MockERC20.sol";
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

    /// @dev Min tick for full range with tick spacing of 60
    int24 internal constant MIN_TICK = -887220;
    /// @dev Max tick for full range with tick spacing of 60
    int24 internal constant MAX_TICK = -MIN_TICK;

    int24 constant TICK_SPACING = 60;
    uint16 constant LOCKED_LIQUIDITY = 1000;
    uint256 constant MAX_DEADLINE = 12329839823;
    uint256 constant MAX_TICK_LIQUIDITY = 11505069308564788430434325881101413;

    MockERC20 token0;
    MockERC20 token1;
    MockERC20 token2;

    PoolManager manager;
    FullRangeImplementation fullRange = FullRangeImplementation(
        address(uint160(Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_MODIFY_POSITION_FLAG | Hooks.BEFORE_SWAP_FLAG))
    );

    PoolKey key;
    PoolId id;

    PoolKey key2;
    PoolId id2;

    PoolModifyPositionTest modifyPositionRouter;
    PoolSwapTest swapRouter;

    function setUp() public {
        token0 = new MockERC20("token0", "0", 18);
        token1 = new MockERC20("token1", "1", 18);
        token2 = new MockERC20("token2", "2", 18);

        token0.mint(address(this), 2 ** 128);
        token1.mint(address(this), 2 ** 128);
        token2.mint(address(this), 2 ** 128);

        manager = new PoolManager(500000);

        FullRangeImplementation impl = new FullRangeImplementation(manager, fullRange);
        vm.etch(address(fullRange), address(impl).code);

        key = PoolKey(Currency.wrap(address(token0)), Currency.wrap(address(token1)), 3000, TICK_SPACING, fullRange);
        id = key.toId();

        key2 = PoolKey(Currency.wrap(address(token1)), Currency.wrap(address(token2)), 3000, TICK_SPACING, fullRange);
        id2 = key.toId();

        modifyPositionRouter = new PoolModifyPositionTest(manager);
        swapRouter = new PoolSwapTest(manager);

        token0.approve(address(fullRange), type(uint256).max);
        token1.approve(address(fullRange), type(uint256).max);
        token2.approve(address(fullRange), type(uint256).max);
        token0.approve(address(swapRouter), type(uint256).max);
        token1.approve(address(swapRouter), type(uint256).max);
        token2.approve(address(swapRouter), type(uint256).max);
    }

    function testBeforeInitializeAllowsPoolCreation() public {
        PoolKey memory testKey = key;

        vm.expectEmit(true, true, true, true);
        emit Initialize(id, testKey.currency0, testKey.currency1, testKey.fee, testKey.tickSpacing, testKey.hooks);

        snapStart("FullRangeInitialize");
        manager.initialize(testKey, SQRT_RATIO_1_1);
        snapEnd();

        (, address liquidityToken) = fullRange.poolInfo(id);

        assertFalse(liquidityToken == address(0));
    }

    function testBeforeInitializeRevertsIfWrongSpacing() public {
        PoolKey memory wrongKey =
            PoolKey(Currency.wrap(address(token0)), Currency.wrap(address(token1)), 0, TICK_SPACING + 1, fullRange);

        vm.expectRevert(FullRange.TickSpacingNotDefault.selector);
        manager.initialize(wrongKey, SQRT_RATIO_1_1);
    }

    function testInitialAddLiquiditySucceeds() public {
        manager.initialize(key, SQRT_RATIO_1_1);

        uint256 prevBalance0 = MockERC20(token0).balanceOf(address(this));
        uint256 prevBalance1 = MockERC20(token1).balanceOf(address(this));

        address token0Addr = address(token0);
        address token1Addr = address(token1);

        snapStart("FullRangeAddLiquidity");
        fullRange.addLiquidity(token0Addr, token1Addr, 3000, 10 ether, 10 ether, address(this), MAX_DEADLINE);
        snapEnd();

        (bool hasAccruedFees, address liquidityToken) = fullRange.poolInfo(id);

        assertEq(MockERC20(token0).balanceOf(address(this)), prevBalance0 - 10 ether);
        assertEq(MockERC20(token1).balanceOf(address(this)), prevBalance1 - 10 ether);

        assertEq(UniswapV4ERC20(liquidityToken).balanceOf(address(this)), 10 ether - LOCKED_LIQUIDITY);
        assertEq(hasAccruedFees, false);
    }

    function testInitialAddLiquidityFuzz(uint256 amount) public {
        manager.initialize(key, SQRT_RATIO_1_1);
        if (amount <= LOCKED_LIQUIDITY) {
            vm.expectRevert(FullRange.LiquidityDoesntMeetMinimum.selector);
            fullRange.addLiquidity(address(token0), address(token1), 3000, amount, amount, address(this), MAX_DEADLINE);
        } else if (amount > MAX_TICK_LIQUIDITY) {
            vm.expectRevert();
            fullRange.addLiquidity(address(token0), address(token1), 3000, amount, amount, address(this), MAX_DEADLINE);
        } else {
            fullRange.addLiquidity(address(token0), address(token1), 3000, amount, amount, address(this), MAX_DEADLINE);

            (bool hasAccruedFees,) = fullRange.poolInfo(id);
            assertEq(hasAccruedFees, false);
        }
    }

    function testAddLiquidityFailsIfNoPool() public {
        vm.expectRevert(FullRange.PoolNotInitialized.selector);
        fullRange.addLiquidity(address(token0), address(token1), 0, 10 ether, 10 ether, address(this), MAX_DEADLINE);
    }

    function testSwapAddLiquiditySucceeds() public {
        PoolKey memory testKey = key;
        manager.initialize(key, SQRT_RATIO_1_1);

        uint256 prevBalance0 = MockERC20(token0).balanceOf(address(this));
        uint256 prevBalance1 = MockERC20(token1).balanceOf(address(this));
        (, address liquidityToken) = fullRange.poolInfo(id);

        fullRange.addLiquidity(address(token0), address(token1), 3000, 10 ether, 10 ether, address(this), MAX_DEADLINE);

        assertEq(UniswapV4ERC20(liquidityToken).balanceOf(address(this)), 10 ether - LOCKED_LIQUIDITY);
        assertEq(MockERC20(token0).balanceOf(address(this)), prevBalance0 - 10 ether);
        assertEq(MockERC20(token0).balanceOf(address(this)), prevBalance1 - 10 ether);

        vm.expectEmit(true, true, true, true);
        emit Swap(
            id, address(swapRouter), 1 ether, -906610893880149131, 72045250990510446115798809072, 10 ether, -1901, 3000
        );

        IPoolManager.SwapParams memory params =
            IPoolManager.SwapParams({zeroForOne: true, amountSpecified: 1 ether, sqrtPriceLimitX96: SQRT_RATIO_1_2});
        PoolSwapTest.TestSettings memory settings =
            PoolSwapTest.TestSettings({withdrawTokens: true, settleUsingTransfer: true});

        snapStart("FullRangeSwap");
        swapRouter.swap(testKey, params, settings);
        snapEnd();

        (bool hasAccruedFees,) = fullRange.poolInfo(id);

        assertEq(MockERC20(token0).balanceOf(address(this)), prevBalance0 - 10 ether - 1 ether);
        assertEq(MockERC20(token1).balanceOf(address(this)), prevBalance1 - 9093389106119850869);
        assertEq(hasAccruedFees, true);

        fullRange.addLiquidity(address(token0), address(token1), 3000, 5 ether, 5 ether, address(this), MAX_DEADLINE);

        (hasAccruedFees,) = fullRange.poolInfo(id);

        assertEq(UniswapV4ERC20(liquidityToken).balanceOf(address(this)), 14546694553059925434 - LOCKED_LIQUIDITY);
        assertEq(hasAccruedFees, true);
    }

    function testTwoSwaps() public {
        PoolKey memory testKey = key;
        manager.initialize(testKey, SQRT_RATIO_1_1);

        fullRange.addLiquidity(address(token0), address(token1), 3000, 10 ether, 10 ether, address(this), MAX_DEADLINE);

        IPoolManager.SwapParams memory params =
            IPoolManager.SwapParams({zeroForOne: true, amountSpecified: 1 ether, sqrtPriceLimitX96: SQRT_RATIO_1_2});
        PoolSwapTest.TestSettings memory settings =
            PoolSwapTest.TestSettings({withdrawTokens: true, settleUsingTransfer: true});

        snapStart("FullRangeFirstSwap");
        swapRouter.swap(testKey, params, settings);
        snapEnd();

        (bool hasAccruedFees,) = fullRange.poolInfo(id);
        assertEq(hasAccruedFees, true);

        snapStart("FullRangeSecondSwap");
        swapRouter.swap(testKey, params, settings);
        snapEnd();

        (hasAccruedFees,) = fullRange.poolInfo(id);
        assertEq(hasAccruedFees, true);
    }

    function testSwapAddLiquidityTwoPools() public {
        manager.initialize(key, SQRT_RATIO_1_1);
        manager.initialize(key2, SQRT_RATIO_1_1);

        fullRange.addLiquidity(address(token0), address(token1), 3000, 10 ether, 10 ether, address(this), MAX_DEADLINE);
        fullRange.addLiquidity(address(token1), address(token2), 3000, 10 ether, 10 ether, address(this), MAX_DEADLINE);

        IPoolManager.SwapParams memory params =
            IPoolManager.SwapParams({zeroForOne: true, amountSpecified: 10000000, sqrtPriceLimitX96: SQRT_RATIO_1_2});

        PoolSwapTest.TestSettings memory testSettings =
            PoolSwapTest.TestSettings({withdrawTokens: true, settleUsingTransfer: true});

        swapRouter.swap(key, params, testSettings);
        swapRouter.swap(key2, params, testSettings);

        (bool hasAccruedFees,) = fullRange.poolInfo(id);
        assertEq(hasAccruedFees, true);

        (hasAccruedFees,) = fullRange.poolInfo(id2);
        assertEq(hasAccruedFees, true);
    }

    function testInitialRemoveLiquiditySucceeds() public {
        manager.initialize(key, SQRT_RATIO_1_1);

        uint256 prevBalance0 = MockERC20(token0).balanceOf(address(this));
        uint256 prevBalance1 = MockERC20(token1).balanceOf(address(this));

        address token0Addr = address(token0);
        address token1Addr = address(token1);

        fullRange.addLiquidity(token0Addr, token1Addr, 3000, 10 ether, 10 ether, address(this), MAX_DEADLINE);

        (, address liquidityToken) = fullRange.poolInfo(id);

        assertEq(UniswapV4ERC20(liquidityToken).balanceOf(address(this)), 10 ether - LOCKED_LIQUIDITY);

        assertEq(MockERC20(token0).balanceOf(address(this)), prevBalance0 - 10 ether);
        assertEq(MockERC20(token1).balanceOf(address(this)), prevBalance1 - 10 ether);

        UniswapV4ERC20(liquidityToken).approve(address(fullRange), type(uint256).max);

        snapStart("FullRangeRemoveLiquidity");
        fullRange.removeLiquidity(token0Addr, token1Addr, 3000, 1 ether, MAX_DEADLINE);
        snapEnd();

        (bool hasAccruedFees,) = fullRange.poolInfo(id);

        assertEq(UniswapV4ERC20(liquidityToken).balanceOf(address(this)), 9 ether - LOCKED_LIQUIDITY);
        assertEq(MockERC20(token0).balanceOf(address(this)), prevBalance0 - 9 ether - 1);
        assertEq(MockERC20(token1).balanceOf(address(this)), prevBalance1 - 9 ether - 1);
        assertEq(hasAccruedFees, false);
    }

    function testInitialRemoveLiquidityFuzz(uint256 amount) public {
        manager.initialize(key, SQRT_RATIO_1_1);

        fullRange.addLiquidity(
            address(token0), address(token1), 3000, 1000 ether, 1000 ether, address(this), MAX_DEADLINE
        );

        (, address liquidityToken) = fullRange.poolInfo(id);

        UniswapV4ERC20(liquidityToken).approve(address(fullRange), type(uint256).max);

        if (amount > 1000 ether - LOCKED_LIQUIDITY) {
            vm.expectRevert();
            fullRange.removeLiquidity(address(token0), address(token1), 3000, amount, MAX_DEADLINE);
        } else {
            fullRange.removeLiquidity(address(token0), address(token1), 3000, amount, MAX_DEADLINE);

            (bool hasAccruedFees,) = fullRange.poolInfo(id);
            assertEq(hasAccruedFees, false);
        }
    }

    function testRemoveLiquidityFailsIfNoPool() public {
        vm.expectRevert(FullRange.PoolNotInitialized.selector);
        fullRange.removeLiquidity(address(token0), address(token1), 0, 10 ether, MAX_DEADLINE);
    }

    function testRemoveLiquidityFailsIfNoLiquidity() public {
        manager.initialize(key, SQRT_RATIO_1_1);

        (, address liquidityToken) = fullRange.poolInfo(id);
        UniswapV4ERC20(liquidityToken).approve(address(fullRange), type(uint256).max);

        vm.expectRevert(); // Insufficient balance error from ERC20 contract
        fullRange.removeLiquidity(address(token0), address(token1), 3000, 10 ether, MAX_DEADLINE);
    }

    function testRemoveLiquiditySucceedsWithPartial() public {
        manager.initialize(key, SQRT_RATIO_1_1);

        uint256 prevBalance0 = MockERC20(token0).balanceOf(address(this));
        uint256 prevBalance1 = MockERC20(token1).balanceOf(address(this));

        fullRange.addLiquidity(address(token0), address(token1), 3000, 10 ether, 10 ether, address(this), MAX_DEADLINE);

        (, address liquidityToken) = fullRange.poolInfo(id);

        assertEq(UniswapV4ERC20(liquidityToken).balanceOf(address(this)), 10 ether - LOCKED_LIQUIDITY);

        assertEq(MockERC20(token0).balanceOf(address(this)), prevBalance0 - 10 ether);
        assertEq(MockERC20(token1).balanceOf(address(this)), prevBalance1 - 10 ether);

        UniswapV4ERC20(liquidityToken).approve(address(fullRange), type(uint256).max);

        fullRange.removeLiquidity(address(token0), address(token1), 3000, 5 ether, MAX_DEADLINE);

        (bool hasAccruedFees,) = fullRange.poolInfo(id);

        assertEq(UniswapV4ERC20(liquidityToken).balanceOf(address(this)), 5 ether - LOCKED_LIQUIDITY);
        assertEq(MockERC20(token0).balanceOf(address(this)), prevBalance0 - 5 ether - 1);
        assertEq(MockERC20(token1).balanceOf(address(this)), prevBalance1 - 5 ether - 1);
        assertEq(hasAccruedFees, false);
    }

    function testRemoveLiquidityWithDiffRatios() public {
        manager.initialize(key, SQRT_RATIO_1_1);

        uint256 prevBalance0 = MockERC20(token0).balanceOf(address(this));
        uint256 prevBalance1 = MockERC20(token1).balanceOf(address(this));

        fullRange.addLiquidity(address(token0), address(token1), 3000, 10 ether, 10 ether, address(this), MAX_DEADLINE);

        assertEq(MockERC20(token0).balanceOf(address(this)), prevBalance0 - 10 ether);
        assertEq(MockERC20(token1).balanceOf(address(this)), prevBalance1 - 10 ether);

        (, address liquidityToken) = fullRange.poolInfo(id);

        assertEq(UniswapV4ERC20(liquidityToken).balanceOf(address(this)), 10 ether - LOCKED_LIQUIDITY);

        fullRange.addLiquidity(address(token0), address(token1), 3000, 5 ether, 2.5 ether, address(this), MAX_DEADLINE);

        assertEq(MockERC20(token0).balanceOf(address(this)), prevBalance0 - 12.5 ether);
        assertEq(MockERC20(token1).balanceOf(address(this)), prevBalance1 - 12.5 ether);

        assertEq(UniswapV4ERC20(liquidityToken).balanceOf(address(this)), 12.5 ether - LOCKED_LIQUIDITY);

        UniswapV4ERC20(liquidityToken).approve(address(fullRange), type(uint256).max);

        fullRange.removeLiquidity(address(token0), address(token1), 3000, 5 ether, MAX_DEADLINE);

        assertEq(MockERC20(token0).balanceOf(address(this)), prevBalance0 - 7.5 ether - 1);
        assertEq(MockERC20(token1).balanceOf(address(this)), prevBalance1 - 7.5 ether - 1);

        assertEq(UniswapV4ERC20(liquidityToken).balanceOf(address(this)), 7.5 ether - LOCKED_LIQUIDITY);
    }

    function testSwapRemoveLiquiditySucceedsWithRebalance() public {
        manager.initialize(key, SQRT_RATIO_1_1);

        fullRange.addLiquidity(address(token0), address(token1), 3000, 10 ether, 10 ether, address(this), MAX_DEADLINE);

        (, address liquidityToken) = fullRange.poolInfo(id);

        assertEq(UniswapV4ERC20(liquidityToken).balanceOf(address(this)), 10 ether - LOCKED_LIQUIDITY);

        IPoolManager.SwapParams memory params =
            IPoolManager.SwapParams({zeroForOne: true, amountSpecified: 1 ether, sqrtPriceLimitX96: SQRT_RATIO_1_2});

        PoolSwapTest.TestSettings memory testSettings =
            PoolSwapTest.TestSettings({withdrawTokens: true, settleUsingTransfer: true});

        swapRouter.swap(key, params, testSettings);

        UniswapV4ERC20(liquidityToken).approve(address(fullRange), type(uint256).max);

        snapStart("FullRangeRemoveLiquidityAndRebalance");
        fullRange.removeLiquidity(address(token0), address(token1), 3000, 5 ether, MAX_DEADLINE);
        snapEnd();

        (bool hasAccruedFees,) = fullRange.poolInfo(id);
        assertEq(hasAccruedFees, false);
    }

    function testThreeLPsRemoveLiquidityWithFees() public {
        // Mint tokens for dummy addresses
        token0.mint(address(1), 2 ** 128);
        token1.mint(address(1), 2 ** 128);
        token0.mint(address(2), 2 ** 128);
        token1.mint(address(2), 2 ** 128);

        // Approve the hook
        vm.prank(address(1));
        token0.approve(address(fullRange), type(uint256).max);
        vm.prank(address(1));
        token1.approve(address(fullRange), type(uint256).max);

        vm.prank(address(2));
        token0.approve(address(fullRange), type(uint256).max);
        vm.prank(address(2));
        token1.approve(address(fullRange), type(uint256).max);

        manager.initialize(key, SQRT_RATIO_1_1);
        (, address liquidityToken) = fullRange.poolInfo(id);

        // Test contract adds liquidity
        fullRange.addLiquidity(address(token0), address(token1), 3000, 100 ether, 100 ether, address(this), MAX_DEADLINE);

        // address(1) adds liquidity
        vm.prank(address(1));
        fullRange.addLiquidity(address(token0), address(token1), 3000, 100 ether, 100 ether, address(this), MAX_DEADLINE);

        // address(2) adds liquidity
        vm.prank(address(2));
        fullRange.addLiquidity(address(token0), address(token1), 3000, 100 ether, 100 ether, address(this), MAX_DEADLINE);

        IPoolManager.SwapParams memory params =
            IPoolManager.SwapParams({zeroForOne: true, amountSpecified: 100 ether, sqrtPriceLimitX96: SQRT_RATIO_1_4});

        PoolSwapTest.TestSettings memory testSettings =
            PoolSwapTest.TestSettings({withdrawTokens: true, settleUsingTransfer: true});

        swapRouter.swap(key, params, testSettings);

        (bool hasAccruedFees,) = fullRange.poolInfo(id);
        assertEq(hasAccruedFees, true);

        console.log(UniswapV4ERC20(liquidityToken).balanceOf(address(this)));

        // Test contract removes liquidity
        UniswapV4ERC20(liquidityToken).approve(address(fullRange), type(uint256).max);
        BalanceDelta testDelta = fullRange.removeLiquidity(address(token0), address(token1), 3000, 300 ether - LOCKED_LIQUIDITY, MAX_DEADLINE);

        console.log(manager.getLiquidity(id));

        // address(1) removes liquidity
        // vm.prank(address(1));
        // UniswapV4ERC20(liquidityToken).approve(address(fullRange), type(uint256).max);
        // vm.prank(address(1));
        // BalanceDelta addrOneDelta = fullRange.removeLiquidity(address(token0), address(token1), 3000, 100 ether, MAX_DEADLINE);

        // // address(2) removes liquidity
        // vm.prank(address(2));
        // UniswapV4ERC20(liquidityToken).approve(address(fullRange), type(uint256).max);
        // vm.prank(address(2));
        // BalanceDelta addrTwoDelta = fullRange.removeLiquidity(address(token0), address(token1), 3000, 100 ether, MAX_DEADLINE);

        // Check if there is leftover principal in the pool



        // Now, we have a new sqrt price ratio for the pool due to swapping AND rebalancing
        // (uint160 newSqrtPriceX96,,,,,) = poolManager.getSlot0(id);

        // Get the amounts for the liquidity and sqrt ratio.
        // How do i calculate whether the fees got accrued, and if they are in the right ratios? - for now, let's just see if there's any principal left in the pool
        // after all three removals

        // LiquidityAmounts.getLiquidityForAmounts(
        //     sqrtPriceX96,
        //     TickMath.getSqrtRatioAtTick(MIN_TICK),
        //     TickMath.getSqrtRatioAtTick(MAX_TICK),
        //     amountADesired,
        //     amountBDesired
        // );

        // (hasAccruedFees,) = fullRange.poolInfo(id);
        // assertEq(hasAccruedFees, false);
        
    }

    /*
    Would be really nice to have a test where multiple (3?) parties add liquidity, earn some significant fees through a few big swaps, and then each pull liquidity and each end up with the right proportion of principal/fees.

Would be good to test beforeSwap() sets owed accurately
    */

    function testBeforeModifyPositionFailsWithWrongMsgSender() public {
        manager.initialize(key, SQRT_RATIO_1_1);

        vm.expectRevert("Sender must be hook");

        modifyPositionRouter.modifyPosition(
            key, IPoolManager.ModifyPositionParams({tickLower: MIN_TICK, tickUpper: MAX_TICK, liquidityDelta: 100})
        );
    }
}
