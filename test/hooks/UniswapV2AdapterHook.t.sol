// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {UniswapV2FactoryDeployer} from "@uniswap/briefcase/src/deployers/v2-core/UniswapV2FactoryDeployer.sol";
import {IUniswapV2Factory} from "@uniswap/briefcase/src/protocols/v2-core/interfaces/IUniswapV2Factory.sol";
import {IUniswapV2Pair} from "@uniswap/briefcase/src/protocols/v2-core/interfaces/IUniswapV2Pair.sol";

import {UniswapV2AdapterHook} from "../../src/hooks/UniswapV2AdapterHook.sol";

contract UniswapV2AdapterHookTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    UniswapV2AdapterHook public hook;
    IUniswapV2Factory public v2Factory;
    MockERC20 public token0;
    MockERC20 public token1;
    PoolKey poolKey;
    uint160 initSqrtPriceX96;

    // Users
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    function setUp() public {
        deployFreshManagerAndRouters();

        // Deploy mock tokens
        token0 = new MockERC20("Token0", "TK0", 18);
        token1 = new MockERC20("Token1", "TK1", 18);
        vm.label(address(token0), "Token0");
        vm.label(address(token1), "Token1");

        // Ensure token0 address < token1 address
        if (address(token0) > address(token1)) {
            (token0, token1) = (token1, token0);
        }

        // Deploy V2 factory and create pair
        v2Factory = UniswapV2FactoryDeployer.deploy(address(0));
        address pair = v2Factory.createPair(address(token0), address(token1));

        // Deploy V2 adapter hook
        hook = UniswapV2AdapterHook(
            address(
                uint160(
                    type(uint160).max & clearAllHookPermissionsMask | Hooks.BEFORE_SWAP_FLAG
                        | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
                        | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.BEFORE_INITIALIZE_FLAG
                )
            )
        );
        deployCodeTo(
            "./foundry-out/UniswapV2AdapterHook.sol/UniswapV2AdapterHook.default.json",
            abi.encode(manager, v2Factory),
            address(hook)
        );

        // Create pool key for token0/token1
        poolKey = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: 3000, // Must match V2's 0.3% fee
            tickSpacing: hook.V2_TICK_SPACING(),
            hooks: IHooks(address(hook))
        });

        // Initialize V4 pool
        initSqrtPriceX96 = uint160(TickMath.getSqrtPriceAtTick(0));
        manager.initialize(poolKey, initSqrtPriceX96);

        // Add liquidity to V2 pair
        token0.mint(pair, 100 ether);
        token1.mint(pair, 100 ether);
        vm.startPrank(alice);
        IUniswapV2Pair(pair).mint(alice);
        vm.stopPrank();

        _addUnrelatedLiquidity();
    }

    function test_initialization() public view {
        assertEq(address(hook.v2Factory()), address(v2Factory));
        assertEq(hook.V2_POOL_FEE(), 3000);
    }

    function test_swap_exactInput_zeroForOne() public {
        uint256 swapAmount = 1 ether;
        uint256 expectedOutput = _getV2AmountOut(swapAmount, address(token0), address(token1));

        vm.startPrank(alice);
        token0.mint(alice, swapAmount);
        token0.approve(address(swapRouter), type(uint256).max);

        uint256 aliceToken0Before = token0.balanceOf(alice);
        uint256 aliceToken1Before = token1.balanceOf(alice);
        uint256 managerToken0Before = token0.balanceOf(address(manager));
        uint256 managerToken1Before = token1.balanceOf(address(manager));

        PoolSwapTest.TestSettings memory testSettings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});
        swapRouter.swap(
            poolKey,
            IPoolManager.SwapParams({
                zeroForOne: true,
                amountSpecified: -int256(swapAmount),
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            testSettings,
            ""
        );

        vm.stopPrank();

        assertEq(aliceToken0Before - token0.balanceOf(alice), swapAmount);
        assertEq(token1.balanceOf(alice) - aliceToken1Before, expectedOutput);
        assertEq(managerToken0Before, token0.balanceOf(address(manager)));
        assertEq(managerToken1Before, token1.balanceOf(address(manager)));
    }

    function test_swap_exactInput_oneForZero() public {
        uint256 swapAmount = 1 ether;
        uint256 expectedOutput = _getV2AmountOut(swapAmount, address(token1), address(token0));

        vm.startPrank(alice);
        token1.mint(alice, swapAmount);
        token1.approve(address(swapRouter), type(uint256).max);

        uint256 aliceToken0Before = token0.balanceOf(alice);
        uint256 aliceToken1Before = token1.balanceOf(alice);
        uint256 managerToken0Before = token0.balanceOf(address(manager));
        uint256 managerToken1Before = token1.balanceOf(address(manager));

        PoolSwapTest.TestSettings memory testSettings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});
        swapRouter.swap(
            poolKey,
            IPoolManager.SwapParams({
                zeroForOne: false,
                amountSpecified: -int256(swapAmount),
                sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
            }),
            testSettings,
            ""
        );

        vm.stopPrank();

        assertEq(aliceToken1Before - token1.balanceOf(alice), swapAmount);
        assertEq(token0.balanceOf(alice) - aliceToken0Before, expectedOutput);
        assertEq(managerToken0Before, token0.balanceOf(address(manager)));
        assertEq(managerToken1Before, token1.balanceOf(address(manager)));
    }

    function test_swap_exactOutput_zeroForOne() public {
        uint256 outputAmount = 1 ether;
        uint256 expectedInput = _getV2AmountIn(outputAmount, address(token0), address(token1));

        vm.startPrank(alice);
        token0.mint(alice, 100 ether);
        token0.approve(address(swapRouter), type(uint256).max);

        uint256 aliceToken0Before = token0.balanceOf(alice);
        uint256 aliceToken1Before = token1.balanceOf(alice);
        uint256 managerToken0Before = token0.balanceOf(address(manager));
        uint256 managerToken1Before = token1.balanceOf(address(manager));

        PoolSwapTest.TestSettings memory testSettings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});
        swapRouter.swap(
            poolKey,
            IPoolManager.SwapParams({
                zeroForOne: true,
                amountSpecified: int256(outputAmount),
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            testSettings,
            ""
        );

        vm.stopPrank();

        assertEq(aliceToken0Before - token0.balanceOf(alice), expectedInput);
        assertEq(token1.balanceOf(alice) - aliceToken1Before, outputAmount);
        assertEq(managerToken0Before, token0.balanceOf(address(manager)));
        assertEq(managerToken1Before, token1.balanceOf(address(manager)));
    }

    function test_swap_exactOutput_oneForZero() public {
        uint256 outputAmount = 1 ether;
        uint256 expectedInput = _getV2AmountIn(outputAmount, address(token1), address(token0));

        vm.startPrank(alice);
        token1.mint(alice, 100 ether);
        token1.approve(address(swapRouter), type(uint256).max);

        uint256 aliceToken0Before = token0.balanceOf(alice);
        uint256 aliceToken1Before = token1.balanceOf(alice);
        uint256 managerToken0Before = token0.balanceOf(address(manager));
        uint256 managerToken1Before = token1.balanceOf(address(manager));

        PoolSwapTest.TestSettings memory testSettings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});
        swapRouter.swap(
            poolKey,
            IPoolManager.SwapParams({
                zeroForOne: false,
                amountSpecified: int256(outputAmount),
                sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
            }),
            testSettings,
            ""
        );

        vm.stopPrank();

        assertEq(aliceToken1Before - token1.balanceOf(alice), expectedInput);
        assertEq(token0.balanceOf(alice) - aliceToken0Before, outputAmount);
        assertEq(managerToken0Before, token0.balanceOf(address(manager)));
        assertEq(managerToken1Before, token1.balanceOf(address(manager)));
    }

    function test_revertAddLiquidity() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook),
                IHooks.beforeAddLiquidity.selector,
                abi.encodeWithSelector(UniswapV2AdapterHook.LiquidityNotAllowed.selector),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );

        modifyLiquidityRouter.modifyLiquidity(
            poolKey,
            IPoolManager.ModifyLiquidityParams({
                tickLower: -120,
                tickUpper: 120,
                liquidityDelta: 1000e18,
                salt: bytes32(0)
            }),
            ""
        );
    }

    function test_revertRemoveLiquidity() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook),
                IHooks.beforeRemoveLiquidity.selector,
                abi.encodeWithSelector(UniswapV2AdapterHook.LiquidityNotAllowed.selector),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );

        modifyLiquidityRouter.modifyLiquidity(
            poolKey,
            IPoolManager.ModifyLiquidityParams({
                tickLower: -120,
                tickUpper: 120,
                liquidityDelta: -1000e18,
                salt: bytes32(0)
            }),
            ""
        );
    }

    function test_revertInvalidPoolInitialization() public {
        // Try to initialize with wrong fee
        PoolKey memory invalidKey = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: 100, // Invalid: must be 3000 to match V2
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });

        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook),
                IHooks.beforeInitialize.selector,
                abi.encodeWithSelector(UniswapV2AdapterHook.InvalidPoolFee.selector),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        manager.initialize(invalidKey, initSqrtPriceX96);

        // Try to initialize without V2 pair
        MockERC20 randomToken = new MockERC20("Random", "RND", 18);
        invalidKey = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(randomToken)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });

        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook),
                IHooks.beforeInitialize.selector,
                abi.encodeWithSelector(UniswapV2AdapterHook.V2PairDoesNotExist.selector),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        manager.initialize(invalidKey, initSqrtPriceX96);
    }

    // Helper to calculate V2 output amount
    function _getV2AmountOut(uint256 amountIn, address tokenIn, address tokenOut)
        internal
        view
        returns (uint256 amountOut)
    {
        IUniswapV2Pair pair = IUniswapV2Pair(v2Factory.getPair(tokenIn, tokenOut));
        (uint112 reserve0, uint112 reserve1,) = pair.getReserves();
        (uint112 reserveIn, uint112 reserveOut) = tokenIn < tokenOut ? (reserve0, reserve1) : (reserve1, reserve0);

        uint256 amountInWithFee = amountIn * 997;
        uint256 numerator = amountInWithFee * reserveOut;
        uint256 denominator = reserveIn * 1000 + amountInWithFee;
        amountOut = numerator / denominator;
    }

    // Helper to calculate V2 input amount
    function _getV2AmountIn(uint256 amountOut, address tokenIn, address tokenOut)
        internal
        view
        returns (uint256 amountIn)
    {
        IUniswapV2Pair pair = IUniswapV2Pair(v2Factory.getPair(tokenIn, tokenOut));
        (uint112 reserve0, uint112 reserve1,) = pair.getReserves();
        (uint112 reserveIn, uint112 reserveOut) = tokenIn < tokenOut ? (reserve0, reserve1) : (reserve1, reserve0);

        uint256 numerator = reserveIn * amountOut * 1000;
        uint256 denominator = (reserveOut - amountOut) * 997;
        amountIn = (numerator / denominator) + 1;
    }

    function _addUnrelatedLiquidity() internal {
        // Create a hookless pool key for ETH/WETH
        PoolKey memory unrelatedPoolKey = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: 100,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });

        manager.initialize(unrelatedPoolKey, uint160(TickMath.getSqrtPriceAtTick(0)));

        token0.mint(address(this), 100 ether);
        token1.mint(address(this), 100 ether);
        token0.approve(address(modifyLiquidityRouter), type(uint256).max);
        token1.approve(address(modifyLiquidityRouter), type(uint256).max);
        modifyLiquidityRouter.modifyLiquidity{value: 100 ether}(
            unrelatedPoolKey,
            IPoolManager.ModifyLiquidityParams({
                tickLower: -120,
                tickUpper: 120,
                liquidityDelta: 1000e18,
                salt: bytes32(0)
            }),
            ""
        );
    }
}
