// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {Test} from "forge-std/Test.sol";
import {GasSnapshot} from "forge-gas-snapshot/GasSnapshot.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {FullRange} from "../contracts/hooks/examples/FullRange.sol";
import {FullRangeImplementation} from "./shared/implementation/FullRangeImplementation.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {UniswapV4ERC20} from "../contracts/libraries/UniswapV4ERC20.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import {HookEnabledSwapRouter} from "./utils/HookEnabledSwapRouter.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";

contract TestFullRange is Test, Deployers, GasSnapshot {
    using PoolIdLibrary for PoolKey;
    using SafeCast for uint256;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    event Initialize(
        PoolId poolId,
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
        address sender,
        int128 amount0,
        int128 amount1,
        uint160 sqrtPriceX96,
        uint128 liquidity,
        int24 tick,
        uint24 fee
    );

    HookEnabledSwapRouter router;
    /// @dev Min tick for full range with tick spacing of 60
    int24 internal constant MIN_TICK = -887220;
    /// @dev Max tick for full range with tick spacing of 60
    int24 internal constant MAX_TICK = -MIN_TICK;

    int24 constant TICK_SPACING = 60;
    uint16 constant LOCKED_LIQUIDITY = 1000;
    uint256 constant MAX_DEADLINE = 12329839823;
    uint256 constant MAX_TICK_LIQUIDITY = 11505069308564788430434325881101412;
    uint8 constant DUST = 30;

    MockERC20 token0;
    MockERC20 token1;
    MockERC20 token2;

    FullRangeImplementation fullRange = FullRangeImplementation(
        address(uint160(Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG))
    );

    PoolId id;

    PoolKey key2;
    PoolId id2;

    // For a pool that gets initialized with liquidity in setUp()
    PoolKey keyWithLiq;
    PoolId idWithLiq;

    function setUp() public {
        deployFreshManagerAndRouters();
        router = new HookEnabledSwapRouter(manager);
        MockERC20[] memory tokens = deployTokens(3, 2 ** 128);
        token0 = tokens[0];
        token1 = tokens[1];
        token2 = tokens[2];

        FullRangeImplementation impl = new FullRangeImplementation(manager, fullRange);
        vm.etch(address(fullRange), address(impl).code);

        key = createPoolKey(token0, token1);
        id = key.toId();

        key2 = createPoolKey(token1, token2);
        id2 = key.toId();

        keyWithLiq = createPoolKey(token0, token2);
        idWithLiq = keyWithLiq.toId();

        token0.approve(address(fullRange), type(uint256).max);
        token1.approve(address(fullRange), type(uint256).max);
        token2.approve(address(fullRange), type(uint256).max);
        token0.approve(address(router), type(uint256).max);
        token1.approve(address(router), type(uint256).max);
        token2.approve(address(router), type(uint256).max);

        initPool(keyWithLiq.currency0, keyWithLiq.currency1, fullRange, 3000, SQRT_PRICE_1_1, ZERO_BYTES);
        fullRange.addLiquidity(
            FullRange.AddLiquidityParams(
                keyWithLiq.currency0,
                keyWithLiq.currency1,
                3000,
                100 ether,
                100 ether,
                99 ether,
                99 ether,
                address(this),
                MAX_DEADLINE
            )
        );
    }

    function testFullRange_beforeInitialize_AllowsPoolCreation() public {
        PoolKey memory testKey = key;

        vm.expectEmit(true, true, true, true);
        emit Initialize(id, testKey.currency0, testKey.currency1, testKey.fee, testKey.tickSpacing, testKey.hooks);

        snapStart("FullRangeInitialize");
        manager.initialize(testKey, SQRT_PRICE_1_1, ZERO_BYTES);
        snapEnd();

        (, address liquidityToken) = fullRange.poolInfo(id);

        assertFalse(liquidityToken == address(0));
    }

    function testFullRange_beforeInitialize_RevertsIfWrongSpacing() public {
        PoolKey memory wrongKey = PoolKey(key.currency0, key.currency1, 0, TICK_SPACING + 1, fullRange);

        vm.expectRevert(FullRange.TickSpacingNotDefault.selector);
        manager.initialize(wrongKey, SQRT_PRICE_1_1, ZERO_BYTES);
    }

    function testFullRange_addLiquidity_InitialAddSucceeds() public {
        manager.initialize(key, SQRT_PRICE_1_1, ZERO_BYTES);

        uint256 prevBalance0 = key.currency0.balanceOf(address(this));
        uint256 prevBalance1 = key.currency1.balanceOf(address(this));

        FullRange.AddLiquidityParams memory addLiquidityParams = FullRange.AddLiquidityParams(
            key.currency0, key.currency1, 3000, 10 ether, 10 ether, 9 ether, 9 ether, address(this), MAX_DEADLINE
        );

        snapStart("FullRangeAddInitialLiquidity");
        fullRange.addLiquidity(addLiquidityParams);
        snapEnd();

        (bool hasAccruedFees, address liquidityToken) = fullRange.poolInfo(id);
        uint256 liquidityTokenBal = UniswapV4ERC20(liquidityToken).balanceOf(address(this));

        assertEq(manager.getLiquidity(id), liquidityTokenBal + LOCKED_LIQUIDITY);

        assertEq(key.currency0.balanceOf(address(this)), prevBalance0 - 10 ether);
        assertEq(key.currency1.balanceOf(address(this)), prevBalance1 - 10 ether);

        assertEq(liquidityTokenBal, 10 ether - LOCKED_LIQUIDITY);
        assertEq(hasAccruedFees, false);
    }

    function testFullRange_addLiquidity_InitialAddFuzz(uint256 amount) public {
        manager.initialize(key, SQRT_PRICE_1_1, ZERO_BYTES);
        if (amount <= LOCKED_LIQUIDITY) {
            vm.expectRevert(FullRange.LiquidityDoesntMeetMinimum.selector);
            fullRange.addLiquidity(
                FullRange.AddLiquidityParams(
                    key.currency0, key.currency1, 3000, amount, amount, amount, amount, address(this), MAX_DEADLINE
                )
            );
        } else if (amount > MAX_TICK_LIQUIDITY) {
            vm.expectRevert();
            fullRange.addLiquidity(
                FullRange.AddLiquidityParams(
                    key.currency0, key.currency1, 3000, amount, amount, amount, amount, address(this), MAX_DEADLINE
                )
            );
        } else {
            fullRange.addLiquidity(
                FullRange.AddLiquidityParams(
                    key.currency0, key.currency1, 3000, amount, amount, 0, 0, address(this), MAX_DEADLINE
                )
            );

            (bool hasAccruedFees, address liquidityToken) = fullRange.poolInfo(id);
            uint256 liquidityTokenBal = UniswapV4ERC20(liquidityToken).balanceOf(address(this));

            assertEq(manager.getLiquidity(id), liquidityTokenBal + LOCKED_LIQUIDITY);
            assertEq(hasAccruedFees, false);
        }
    }

    function testFullRange_addLiquidity_SubsequentAdd() public {
        uint256 prevBalance0 = keyWithLiq.currency0.balanceOfSelf();
        uint256 prevBalance1 = keyWithLiq.currency1.balanceOfSelf();

        (, address liquidityToken) = fullRange.poolInfo(idWithLiq);
        uint256 prevLiquidityTokenBal = UniswapV4ERC20(liquidityToken).balanceOf(address(this));

        FullRange.AddLiquidityParams memory addLiquidityParams = FullRange.AddLiquidityParams(
            keyWithLiq.currency0,
            keyWithLiq.currency1,
            3000,
            10 ether,
            10 ether,
            9 ether,
            9 ether,
            address(this),
            MAX_DEADLINE
        );

        snapStart("FullRangeAddLiquidity");
        fullRange.addLiquidity(addLiquidityParams);
        snapEnd();

        (bool hasAccruedFees,) = fullRange.poolInfo(idWithLiq);
        uint256 liquidityTokenBal = UniswapV4ERC20(liquidityToken).balanceOf(address(this));

        assertEq(manager.getLiquidity(idWithLiq), liquidityTokenBal + LOCKED_LIQUIDITY);

        assertEq(keyWithLiq.currency0.balanceOfSelf(), prevBalance0 - 10 ether);
        assertEq(keyWithLiq.currency1.balanceOfSelf(), prevBalance1 - 10 ether);

        assertEq(liquidityTokenBal, prevLiquidityTokenBal + 10 ether);
        assertEq(hasAccruedFees, false);
    }

    function testFullRange_addLiquidity_FailsIfNoPool() public {
        vm.expectRevert(FullRange.PoolNotInitialized.selector);
        fullRange.addLiquidity(
            FullRange.AddLiquidityParams(
                key.currency0, key.currency1, 0, 10 ether, 10 ether, 9 ether, 9 ether, address(this), MAX_DEADLINE
            )
        );
    }

    function testFullRange_addLiquidity_SwapThenAddSucceeds() public {
        manager.initialize(key, SQRT_PRICE_1_1, ZERO_BYTES);

        uint256 prevBalance0 = key.currency0.balanceOf(address(this));
        uint256 prevBalance1 = key.currency1.balanceOf(address(this));
        (, address liquidityToken) = fullRange.poolInfo(id);

        fullRange.addLiquidity(
            FullRange.AddLiquidityParams(
                key.currency0, key.currency1, 3000, 10 ether, 10 ether, 9 ether, 9 ether, address(this), MAX_DEADLINE
            )
        );

        uint256 liquidityTokenBal = UniswapV4ERC20(liquidityToken).balanceOf(address(this));

        assertEq(manager.getLiquidity(id), liquidityTokenBal + LOCKED_LIQUIDITY);
        assertEq(liquidityTokenBal, 10 ether - LOCKED_LIQUIDITY);
        assertEq(key.currency0.balanceOf(address(this)), prevBalance0 - 10 ether);
        assertEq(key.currency1.balanceOf(address(this)), prevBalance1 - 10 ether);

        vm.expectEmit(true, true, true, true);
        emit Swap(
            id, address(router), -1 ether, 906610893880149131, 72045250990510446115798809072, 10 ether, -1901, 3000
        );

        IPoolManager.SwapParams memory params =
            IPoolManager.SwapParams({zeroForOne: true, amountSpecified: -1 ether, sqrtPriceLimitX96: SQRT_PRICE_1_2});
        HookEnabledSwapRouter.TestSettings memory settings =
            HookEnabledSwapRouter.TestSettings({takeClaims: false, settleUsingBurn: false});

        snapStart("FullRangeSwap");
        router.swap(key, params, settings, ZERO_BYTES);
        snapEnd();

        (bool hasAccruedFees,) = fullRange.poolInfo(id);

        assertEq(key.currency0.balanceOf(address(this)), prevBalance0 - 10 ether - 1 ether);
        assertEq(key.currency1.balanceOf(address(this)), prevBalance1 - 9093389106119850869);
        assertEq(hasAccruedFees, true);

        fullRange.addLiquidity(
            FullRange.AddLiquidityParams(
                key.currency0, key.currency1, 3000, 5 ether, 5 ether, 4 ether, 4 ether, address(this), MAX_DEADLINE
            )
        );

        (hasAccruedFees,) = fullRange.poolInfo(id);
        liquidityTokenBal = UniswapV4ERC20(liquidityToken).balanceOf(address(this));

        assertEq(manager.getLiquidity(id), liquidityTokenBal + LOCKED_LIQUIDITY);
        assertEq(liquidityTokenBal, 14546694553059925434 - LOCKED_LIQUIDITY);
        assertEq(hasAccruedFees, true);
    }

    function testFullRange_addLiquidity_FailsIfTooMuchSlippage() public {
        manager.initialize(key, SQRT_PRICE_1_1, ZERO_BYTES);

        fullRange.addLiquidity(
            FullRange.AddLiquidityParams(
                key.currency0, key.currency1, 3000, 10 ether, 10 ether, 10 ether, 10 ether, address(this), MAX_DEADLINE
            )
        );

        IPoolManager.SwapParams memory params =
            IPoolManager.SwapParams({zeroForOne: true, amountSpecified: 1000 ether, sqrtPriceLimitX96: SQRT_PRICE_1_2});
        HookEnabledSwapRouter.TestSettings memory settings =
            HookEnabledSwapRouter.TestSettings({takeClaims: false, settleUsingBurn: false});

        router.swap(key, params, settings, ZERO_BYTES);

        vm.expectRevert(FullRange.TooMuchSlippage.selector);
        fullRange.addLiquidity(
            FullRange.AddLiquidityParams(
                key.currency0, key.currency1, 3000, 10 ether, 10 ether, 10 ether, 10 ether, address(this), MAX_DEADLINE
            )
        );
    }

    function testFullRange_swap_TwoSwaps() public {
        PoolKey memory testKey = key;
        manager.initialize(testKey, SQRT_PRICE_1_1, ZERO_BYTES);

        fullRange.addLiquidity(
            FullRange.AddLiquidityParams(
                key.currency0, key.currency1, 3000, 10 ether, 10 ether, 9 ether, 9 ether, address(this), MAX_DEADLINE
            )
        );

        IPoolManager.SwapParams memory params =
            IPoolManager.SwapParams({zeroForOne: true, amountSpecified: 1 ether, sqrtPriceLimitX96: SQRT_PRICE_1_2});
        HookEnabledSwapRouter.TestSettings memory settings =
            HookEnabledSwapRouter.TestSettings({takeClaims: false, settleUsingBurn: false});

        snapStart("FullRangeFirstSwap");
        router.swap(testKey, params, settings, ZERO_BYTES);
        snapEnd();

        (bool hasAccruedFees,) = fullRange.poolInfo(id);
        assertEq(hasAccruedFees, true);

        snapStart("FullRangeSecondSwap");
        router.swap(testKey, params, settings, ZERO_BYTES);
        snapEnd();

        (hasAccruedFees,) = fullRange.poolInfo(id);
        assertEq(hasAccruedFees, true);
    }

    function testFullRange_swap_TwoPools() public {
        manager.initialize(key, SQRT_PRICE_1_1, ZERO_BYTES);
        manager.initialize(key2, SQRT_PRICE_1_1, ZERO_BYTES);

        fullRange.addLiquidity(
            FullRange.AddLiquidityParams(
                key.currency0, key.currency1, 3000, 10 ether, 10 ether, 9 ether, 9 ether, address(this), MAX_DEADLINE
            )
        );
        fullRange.addLiquidity(
            FullRange.AddLiquidityParams(
                key2.currency0, key2.currency1, 3000, 10 ether, 10 ether, 9 ether, 9 ether, address(this), MAX_DEADLINE
            )
        );

        IPoolManager.SwapParams memory params =
            IPoolManager.SwapParams({zeroForOne: true, amountSpecified: 10000000, sqrtPriceLimitX96: SQRT_PRICE_1_2});

        HookEnabledSwapRouter.TestSettings memory testSettings =
            HookEnabledSwapRouter.TestSettings({takeClaims: false, settleUsingBurn: false});

        router.swap(key, params, testSettings, ZERO_BYTES);
        router.swap(key2, params, testSettings, ZERO_BYTES);

        (bool hasAccruedFees,) = fullRange.poolInfo(id);
        assertEq(hasAccruedFees, true);

        (hasAccruedFees,) = fullRange.poolInfo(id2);
        assertEq(hasAccruedFees, true);
    }

    function testFullRange_removeLiquidity_InitialRemoveSucceeds() public {
        uint256 prevBalance0 = keyWithLiq.currency0.balanceOfSelf();
        uint256 prevBalance1 = keyWithLiq.currency1.balanceOfSelf();

        (, address liquidityToken) = fullRange.poolInfo(idWithLiq);

        UniswapV4ERC20(liquidityToken).approve(address(fullRange), type(uint256).max);

        FullRange.RemoveLiquidityParams memory removeLiquidityParams =
            FullRange.RemoveLiquidityParams(keyWithLiq.currency0, keyWithLiq.currency1, 3000, 1 ether, MAX_DEADLINE);

        snapStart("FullRangeRemoveLiquidity");
        fullRange.removeLiquidity(removeLiquidityParams);
        snapEnd();

        (bool hasAccruedFees,) = fullRange.poolInfo(idWithLiq);
        uint256 liquidityTokenBal = UniswapV4ERC20(liquidityToken).balanceOf(address(this));

        assertEq(manager.getLiquidity(idWithLiq), liquidityTokenBal + LOCKED_LIQUIDITY);
        assertEq(UniswapV4ERC20(liquidityToken).balanceOf(address(this)), 99 ether - LOCKED_LIQUIDITY + 5);
        assertEq(keyWithLiq.currency0.balanceOfSelf(), prevBalance0 + 1 ether - 1);
        assertEq(keyWithLiq.currency1.balanceOfSelf(), prevBalance1 + 1 ether - 1);
        assertEq(hasAccruedFees, false);
    }

    function testFullRange_removeLiquidity_InitialRemoveFuzz(uint256 amount) public {
        manager.initialize(key, SQRT_PRICE_1_1, ZERO_BYTES);

        fullRange.addLiquidity(
            FullRange.AddLiquidityParams(
                key.currency0,
                key.currency1,
                3000,
                1000 ether,
                1000 ether,
                999 ether,
                999 ether,
                address(this),
                MAX_DEADLINE
            )
        );

        (, address liquidityToken) = fullRange.poolInfo(id);

        UniswapV4ERC20(liquidityToken).approve(address(fullRange), type(uint256).max);

        if (amount > UniswapV4ERC20(liquidityToken).balanceOf(address(this))) {
            vm.expectRevert();
            fullRange.removeLiquidity(
                FullRange.RemoveLiquidityParams(key.currency0, key.currency1, 3000, amount, MAX_DEADLINE)
            );
        } else {
            uint256 prevLiquidityTokenBal = UniswapV4ERC20(liquidityToken).balanceOf(address(this));
            fullRange.removeLiquidity(
                FullRange.RemoveLiquidityParams(key.currency0, key.currency1, 3000, amount, MAX_DEADLINE)
            );

            uint256 liquidityTokenBal = UniswapV4ERC20(liquidityToken).balanceOf(address(this));
            (bool hasAccruedFees,) = fullRange.poolInfo(id);

            assertEq(prevLiquidityTokenBal - liquidityTokenBal, amount);
            assertEq(manager.getLiquidity(id), liquidityTokenBal + LOCKED_LIQUIDITY);
            assertEq(hasAccruedFees, false);
        }
    }

    function testFullRange_removeLiquidity_FailsIfNoPool() public {
        vm.expectRevert(FullRange.PoolNotInitialized.selector);
        fullRange.removeLiquidity(
            FullRange.RemoveLiquidityParams(key.currency0, key.currency1, 0, 10 ether, MAX_DEADLINE)
        );
    }

    function testFullRange_removeLiquidity_FailsIfNoLiquidity() public {
        manager.initialize(key, SQRT_PRICE_1_1, ZERO_BYTES);

        (, address liquidityToken) = fullRange.poolInfo(id);
        UniswapV4ERC20(liquidityToken).approve(address(fullRange), type(uint256).max);

        vm.expectRevert(); // Insufficient balance error from ERC20 contract
        fullRange.removeLiquidity(
            FullRange.RemoveLiquidityParams(key.currency0, key.currency1, 3000, 10 ether, MAX_DEADLINE)
        );
    }

    function testFullRange_removeLiquidity_SucceedsWithPartial() public {
        manager.initialize(key, SQRT_PRICE_1_1, ZERO_BYTES);

        uint256 prevBalance0 = key.currency0.balanceOfSelf();
        uint256 prevBalance1 = key.currency1.balanceOfSelf();

        fullRange.addLiquidity(
            FullRange.AddLiquidityParams(
                key.currency0, key.currency1, 3000, 10 ether, 10 ether, 9 ether, 9 ether, address(this), MAX_DEADLINE
            )
        );

        (, address liquidityToken) = fullRange.poolInfo(id);

        assertEq(UniswapV4ERC20(liquidityToken).balanceOf(address(this)), 10 ether - LOCKED_LIQUIDITY);

        assertEq(key.currency0.balanceOfSelf(), prevBalance0 - 10 ether);
        assertEq(key.currency1.balanceOfSelf(), prevBalance1 - 10 ether);

        UniswapV4ERC20(liquidityToken).approve(address(fullRange), type(uint256).max);

        fullRange.removeLiquidity(
            FullRange.RemoveLiquidityParams(key.currency0, key.currency1, 3000, 5 ether, MAX_DEADLINE)
        );

        (bool hasAccruedFees,) = fullRange.poolInfo(id);
        uint256 liquidityTokenBal = UniswapV4ERC20(liquidityToken).balanceOf(address(this));

        assertEq(manager.getLiquidity(id), liquidityTokenBal + LOCKED_LIQUIDITY);
        assertEq(liquidityTokenBal, 5 ether - LOCKED_LIQUIDITY);
        assertEq(key.currency0.balanceOfSelf(), prevBalance0 - 5 ether - 1);
        assertEq(key.currency1.balanceOfSelf(), prevBalance1 - 5 ether - 1);
        assertEq(hasAccruedFees, false);
    }

    function testFullRange_removeLiquidity_DiffRatios() public {
        manager.initialize(key, SQRT_PRICE_1_1, ZERO_BYTES);

        uint256 prevBalance0 = key.currency0.balanceOf(address(this));
        uint256 prevBalance1 = key.currency1.balanceOf(address(this));

        fullRange.addLiquidity(
            FullRange.AddLiquidityParams(
                key.currency0, key.currency1, 3000, 10 ether, 10 ether, 9 ether, 9 ether, address(this), MAX_DEADLINE
            )
        );

        assertEq(key.currency0.balanceOf(address(this)), prevBalance0 - 10 ether);
        assertEq(key.currency1.balanceOf(address(this)), prevBalance1 - 10 ether);

        (, address liquidityToken) = fullRange.poolInfo(id);

        assertEq(UniswapV4ERC20(liquidityToken).balanceOf(address(this)), 10 ether - LOCKED_LIQUIDITY);

        fullRange.addLiquidity(
            FullRange.AddLiquidityParams(
                key.currency0, key.currency1, 3000, 5 ether, 2.5 ether, 2 ether, 2 ether, address(this), MAX_DEADLINE
            )
        );

        assertEq(key.currency0.balanceOf(address(this)), prevBalance0 - 12.5 ether);
        assertEq(key.currency1.balanceOf(address(this)), prevBalance1 - 12.5 ether);

        assertEq(UniswapV4ERC20(liquidityToken).balanceOf(address(this)), 12.5 ether - LOCKED_LIQUIDITY);

        UniswapV4ERC20(liquidityToken).approve(address(fullRange), type(uint256).max);

        fullRange.removeLiquidity(
            FullRange.RemoveLiquidityParams(key.currency0, key.currency1, 3000, 5 ether, MAX_DEADLINE)
        );

        uint256 liquidityTokenBal = UniswapV4ERC20(liquidityToken).balanceOf(address(this));

        assertEq(manager.getLiquidity(id), liquidityTokenBal + LOCKED_LIQUIDITY);
        assertEq(liquidityTokenBal, 7.5 ether - LOCKED_LIQUIDITY);
        assertEq(key.currency0.balanceOf(address(this)), prevBalance0 - 7.5 ether - 1);
        assertEq(key.currency1.balanceOf(address(this)), prevBalance1 - 7.5 ether - 1);
    }

    function testFullRange_removeLiquidity_SwapAndRebalance() public {
        (, address liquidityToken) = fullRange.poolInfo(idWithLiq);

        IPoolManager.SwapParams memory params =
            IPoolManager.SwapParams({zeroForOne: true, amountSpecified: 1 ether, sqrtPriceLimitX96: SQRT_PRICE_1_2});

        HookEnabledSwapRouter.TestSettings memory testSettings =
            HookEnabledSwapRouter.TestSettings({takeClaims: false, settleUsingBurn: false});

        router.swap(keyWithLiq, params, testSettings, ZERO_BYTES);

        UniswapV4ERC20(liquidityToken).approve(address(fullRange), type(uint256).max);

        FullRange.RemoveLiquidityParams memory removeLiquidityParams =
            FullRange.RemoveLiquidityParams(keyWithLiq.currency0, keyWithLiq.currency1, 3000, 5 ether, MAX_DEADLINE);

        snapStart("FullRangeRemoveLiquidityAndRebalance");
        fullRange.removeLiquidity(removeLiquidityParams);
        snapEnd();

        (bool hasAccruedFees,) = fullRange.poolInfo(idWithLiq);
        assertEq(hasAccruedFees, false);
    }

    function testFullRange_removeLiquidity_RemoveAllFuzz(uint256 amount) public {
        manager.initialize(key, SQRT_PRICE_1_1, ZERO_BYTES);
        (, address liquidityToken) = fullRange.poolInfo(id);

        if (amount <= LOCKED_LIQUIDITY) {
            vm.expectRevert(FullRange.LiquidityDoesntMeetMinimum.selector);
            fullRange.addLiquidity(
                FullRange.AddLiquidityParams(
                    key.currency0, key.currency1, 3000, amount, amount, amount, amount, address(this), MAX_DEADLINE
                )
            );
        } else if (amount >= MAX_TICK_LIQUIDITY) {
            vm.expectRevert();
            fullRange.addLiquidity(
                FullRange.AddLiquidityParams(
                    key.currency0, key.currency1, 3000, amount, amount, amount, amount, address(this), MAX_DEADLINE
                )
            );
        } else {
            fullRange.addLiquidity(
                FullRange.AddLiquidityParams(
                    key.currency0, key.currency1, 3000, amount, amount, 0, 0, address(this), MAX_DEADLINE
                )
            );

            // Test contract removes liquidity, succeeds
            UniswapV4ERC20(liquidityToken).approve(address(fullRange), type(uint256).max);

            uint256 liquidityTokenBal = UniswapV4ERC20(liquidityToken).balanceOf(address(this));

            fullRange.removeLiquidity(
                FullRange.RemoveLiquidityParams(key.currency0, key.currency1, 3000, liquidityTokenBal, MAX_DEADLINE)
            );

            assertEq(manager.getLiquidity(id), LOCKED_LIQUIDITY);
        }
    }

    function testFullRange_removeLiquidity_ThreeLPsRemovePrincipalAndFees() public {
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

        manager.initialize(key, SQRT_PRICE_1_1, ZERO_BYTES);
        (, address liquidityToken) = fullRange.poolInfo(id);

        // Test contract adds liquidity
        fullRange.addLiquidity(
            FullRange.AddLiquidityParams(
                key.currency0,
                key.currency1,
                3000,
                100 ether,
                100 ether,
                99 ether,
                99 ether,
                address(this),
                MAX_DEADLINE
            )
        );

        // address(1) adds liquidity
        vm.prank(address(1));
        fullRange.addLiquidity(
            FullRange.AddLiquidityParams(
                key.currency0,
                key.currency1,
                3000,
                100 ether,
                100 ether,
                99 ether,
                99 ether,
                address(this),
                MAX_DEADLINE
            )
        );

        // address(2) adds liquidity
        vm.prank(address(2));
        fullRange.addLiquidity(
            FullRange.AddLiquidityParams(
                key.currency0,
                key.currency1,
                3000,
                100 ether,
                100 ether,
                99 ether,
                99 ether,
                address(this),
                MAX_DEADLINE
            )
        );

        IPoolManager.SwapParams memory params =
            IPoolManager.SwapParams({zeroForOne: true, amountSpecified: 100 ether, sqrtPriceLimitX96: SQRT_PRICE_1_4});

        HookEnabledSwapRouter.TestSettings memory testSettings =
            HookEnabledSwapRouter.TestSettings({takeClaims: false, settleUsingBurn: false});

        router.swap(key, params, testSettings, ZERO_BYTES);

        (bool hasAccruedFees,) = fullRange.poolInfo(id);
        assertEq(hasAccruedFees, true);

        // Test contract removes liquidity, succeeds
        UniswapV4ERC20(liquidityToken).approve(address(fullRange), type(uint256).max);
        fullRange.removeLiquidity(
            FullRange.RemoveLiquidityParams(
                key.currency0, key.currency1, 3000, 300 ether - LOCKED_LIQUIDITY, MAX_DEADLINE
            )
        );
        (hasAccruedFees,) = fullRange.poolInfo(id);

        // PoolManager does not have any liquidity left over
        assertTrue(manager.getLiquidity(id) >= LOCKED_LIQUIDITY);
        assertTrue(manager.getLiquidity(id) < LOCKED_LIQUIDITY + DUST);

        assertEq(hasAccruedFees, false);
    }

    function testFullRange_removeLiquidity_SwapRemoveAllFuzz(uint256 amount) public {
        manager.initialize(key, SQRT_PRICE_1_1, ZERO_BYTES);
        (, address liquidityToken) = fullRange.poolInfo(id);

        if (amount <= LOCKED_LIQUIDITY) {
            vm.expectRevert(FullRange.LiquidityDoesntMeetMinimum.selector);
            fullRange.addLiquidity(
                FullRange.AddLiquidityParams(
                    key.currency0, key.currency1, 3000, amount, amount, amount, amount, address(this), MAX_DEADLINE
                )
            );
        } else if (amount >= MAX_TICK_LIQUIDITY) {
            vm.expectRevert();
            fullRange.addLiquidity(
                FullRange.AddLiquidityParams(
                    key.currency0, key.currency1, 3000, amount, amount, amount, amount, address(this), MAX_DEADLINE
                )
            );
        } else {
            fullRange.addLiquidity(
                FullRange.AddLiquidityParams(
                    key.currency0, key.currency1, 3000, amount, amount, 0, 0, address(this), MAX_DEADLINE
                )
            );

            IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
                zeroForOne: true,
                amountSpecified: (FullMath.mulDiv(amount, 1, 4)).toInt256(),
                sqrtPriceLimitX96: SQRT_PRICE_1_4
            });

            HookEnabledSwapRouter.TestSettings memory testSettings =
                HookEnabledSwapRouter.TestSettings({takeClaims: false, settleUsingBurn: false});

            router.swap(key, params, testSettings, ZERO_BYTES);

            // Test contract removes liquidity, succeeds
            UniswapV4ERC20(liquidityToken).approve(address(fullRange), type(uint256).max);

            uint256 liquidityTokenBal = UniswapV4ERC20(liquidityToken).balanceOf(address(this));

            fullRange.removeLiquidity(
                FullRange.RemoveLiquidityParams(key.currency0, key.currency1, 3000, liquidityTokenBal, MAX_DEADLINE)
            );

            assertTrue(manager.getLiquidity(id) <= LOCKED_LIQUIDITY + DUST);
        }
    }

    function testFullRange_BeforeModifyPositionFailsWithWrongMsgSender() public {
        manager.initialize(key, SQRT_PRICE_1_1, ZERO_BYTES);

        vm.expectRevert(FullRange.SenderMustBeHook.selector);
        modifyLiquidityRouter.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({tickLower: MIN_TICK, tickUpper: MAX_TICK, liquidityDelta: 100, salt: 0}),
            ZERO_BYTES
        );
    }

    function createPoolKey(MockERC20 tokenA, MockERC20 tokenB) internal view returns (PoolKey memory) {
        if (address(tokenA) > address(tokenB)) (tokenA, tokenB) = (tokenB, tokenA);
        return PoolKey(Currency.wrap(address(tokenA)), Currency.wrap(address(tokenB)), 3000, TICK_SPACING, fullRange);
    }
}
