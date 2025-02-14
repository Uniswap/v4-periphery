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
import {WETH} from "solmate/src/tokens/WETH.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {Test} from "forge-std/Test.sol";
import {ERC20} from "solmate/src/tokens/ERC20.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {BaseTokenWrapperHook} from "../../src/base/hooks/BaseTokenWrapperHook.sol";
import {WETHHook} from "../../src/hooks/WETHHook.sol";

contract WETHHookTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    WETHHook public hook;
    WETH public weth;
    PoolKey poolKey;
    uint160 initSqrtPriceX96;

    // Users
    address payable alice = payable(makeAddr("alice"));
    address payable bob = payable(makeAddr("bob"));

    event Transfer(address indexed from, address indexed to, uint256 amount);

    function setUp() public {
        deployFreshManagerAndRouters();
        weth = new WETH();

        // Deploy WETH hook
        hook = WETHHook(
            payable(
                address(
                    uint160(
                        type(uint160).max & clearAllHookPermissionsMask | Hooks.BEFORE_SWAP_FLAG
                            | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
                            | Hooks.BEFORE_INITIALIZE_FLAG
                    )
                )
            )
        );
        deployCodeTo("WETHHook", abi.encode(manager, weth), address(hook));

        // Create pool key for ETH/WETH
        poolKey = PoolKey({
            currency0: CurrencyLibrary.ADDRESS_ZERO,
            currency1: Currency.wrap(address(weth)),
            fee: 0, // Must be 0 for wrapper pools
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });

        // Initialize pool at 1:1 price
        initSqrtPriceX96 = uint160(TickMath.getSqrtPriceAtTick(0));
        manager.initialize(poolKey, initSqrtPriceX96);

        // Give users some ETH
        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);
        vm.deal(address(this), 200 ether);
        (bool success,) = address(weth).call{value: 200 ether}("");
        require(success, "WETH transfer failed");
        weth.transfer(alice, 100 ether);
        weth.transfer(bob, 100 ether);
        _addUnrelatedLiquidity();
    }

    function test_initialization() public view {
        assertEq(address(hook.weth()), address(weth));
        assertEq(Currency.unwrap(hook.wrapperCurrency()), address(weth));
        assertEq(Currency.unwrap(hook.underlyingCurrency()), address(0));
    }

    function test_wrapETH() public {
        uint256 wrapAmount = 1 ether;

        uint256 aliceEthBalanceBefore = alice.balance;
        uint256 aliceWethBalanceBefore = weth.balanceOf(address(alice));
        uint256 managerEthBalanceBefore = address(manager).balance;
        uint256 managerWethBalanceBefore = weth.balanceOf(address(manager));

        vm.startPrank(alice);
        vm.expectEmit(true, true, true, true);
        emit Transfer(address(0), address(hook), wrapAmount);
        vm.expectEmit(true, true, true, true);
        emit Transfer(address(manager), address(alice), wrapAmount);

        PoolSwapTest.TestSettings memory testSettings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});
        swapRouter.swap{value: wrapAmount}(
            poolKey,
            IPoolManager.SwapParams({
                zeroForOne: true, // ETH (0) to WETH (1)
                amountSpecified: -int256(wrapAmount),
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            testSettings,
            ""
        );

        vm.stopPrank();

        uint256 aliceEthBalanceAfter = alice.balance;
        uint256 aliceWethBalanceAfter = weth.balanceOf(address(alice));
        uint256 managerEthBalanceAfter = address(manager).balance;
        uint256 managerWethBalanceAfter = weth.balanceOf(address(manager));
        assertEq(aliceEthBalanceBefore - aliceEthBalanceAfter, wrapAmount);
        assertEq(aliceWethBalanceAfter - aliceWethBalanceBefore, wrapAmount);
        assertEq(managerEthBalanceBefore, managerEthBalanceAfter);
        assertEq(managerWethBalanceBefore, managerWethBalanceAfter);
    }

    function test_unwrapWETH() public {
        uint256 unwrapAmount = 1 ether;

        // Directly deposit WETH to the manager
        uint256 aliceEthBalanceBefore = alice.balance;
        uint256 aliceWethBalanceBefore = weth.balanceOf(address(alice));
        uint256 managerEthBalanceBefore = address(manager).balance;
        uint256 managerWethBalanceBefore = weth.balanceOf(address(manager));

        vm.startPrank(alice);
        weth.approve(address(swapRouter), type(uint256).max);
        PoolSwapTest.TestSettings memory testSettings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

        vm.expectEmit(true, true, true, true);
        emit Transfer(address(hook), address(0), unwrapAmount);
        vm.expectEmit(true, true, true, true);
        emit Transfer(address(alice), address(manager), unwrapAmount);

        swapRouter.swap(
            poolKey,
            IPoolManager.SwapParams({
                zeroForOne: false, // WETH (1) to ETH (0)
                amountSpecified: -int256(unwrapAmount),
                sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
            }),
            testSettings,
            ""
        );

        vm.stopPrank();

        uint256 aliceEthBalanceAfter = alice.balance;
        uint256 aliceWethBalanceAfter = weth.balanceOf(address(alice));
        uint256 managerEthBalanceAfter = address(manager).balance;
        uint256 managerWethBalanceAfter = weth.balanceOf(address(manager));
        assertEq(aliceEthBalanceAfter - aliceEthBalanceBefore, unwrapAmount);
        assertEq(aliceWethBalanceBefore - aliceWethBalanceAfter, unwrapAmount);
        assertEq(managerEthBalanceBefore, managerEthBalanceAfter);
        assertEq(managerWethBalanceBefore, managerWethBalanceAfter);
    }

    function test_wrapETH_exactOut() public {
        uint256 wrapAmount = 1 ether;

        uint256 aliceEthBalanceBefore = alice.balance;
        uint256 aliceWethBalanceBefore = weth.balanceOf(address(alice));
        uint256 managerEthBalanceBefore = address(manager).balance;
        uint256 managerWethBalanceBefore = weth.balanceOf(address(manager));

        vm.startPrank(alice);
        vm.expectEmit(true, true, true, true);
        emit Transfer(address(0), address(hook), wrapAmount);
        vm.expectEmit(true, true, true, true);
        emit Transfer(address(manager), address(alice), wrapAmount);

        PoolSwapTest.TestSettings memory testSettings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});
        swapRouter.swap{value: wrapAmount}(
            poolKey,
            IPoolManager.SwapParams({
                zeroForOne: true, // ETH (0) to WETH (1)
                amountSpecified: int256(wrapAmount), // Negative for exact output
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            testSettings,
            ""
        );

        vm.stopPrank();

        uint256 aliceEthBalanceAfter = alice.balance;
        uint256 aliceWethBalanceAfter = weth.balanceOf(address(alice));
        uint256 managerEthBalanceAfter = address(manager).balance;
        uint256 managerWethBalanceAfter = weth.balanceOf(address(manager));
        assertEq(aliceEthBalanceBefore - aliceEthBalanceAfter, wrapAmount);
        assertEq(aliceWethBalanceAfter - aliceWethBalanceBefore, wrapAmount);
        assertEq(managerEthBalanceBefore, managerEthBalanceAfter);
        assertEq(managerWethBalanceBefore, managerWethBalanceAfter);
    }

    function test_unwrapWETH_exactOut() public {
        uint256 unwrapAmount = 1 ether;

        uint256 aliceEthBalanceBefore = alice.balance;
        uint256 aliceWethBalanceBefore = weth.balanceOf(address(alice));
        uint256 managerEthBalanceBefore = address(manager).balance;
        uint256 managerWethBalanceBefore = weth.balanceOf(address(manager));

        vm.startPrank(alice);
        weth.approve(address(swapRouter), type(uint256).max);
        PoolSwapTest.TestSettings memory testSettings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

        vm.expectEmit(true, true, true, true);
        emit Transfer(address(hook), address(0), unwrapAmount);
        vm.expectEmit(true, true, true, true);
        emit Transfer(address(alice), address(manager), unwrapAmount);

        swapRouter.swap(
            poolKey,
            IPoolManager.SwapParams({
                zeroForOne: false, // WETH (1) to ETH (0)
                amountSpecified: int256(unwrapAmount), // Negative for exact output
                sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
            }),
            testSettings,
            ""
        );

        vm.stopPrank();

        uint256 aliceEthBalanceAfter = alice.balance;
        uint256 aliceWethBalanceAfter = weth.balanceOf(address(alice));
        uint256 managerEthBalanceAfter = address(manager).balance;
        uint256 managerWethBalanceAfter = weth.balanceOf(address(manager));
        assertEq(aliceEthBalanceAfter - aliceEthBalanceBefore, unwrapAmount);
        assertEq(aliceWethBalanceBefore - aliceWethBalanceAfter, unwrapAmount);
        assertEq(managerEthBalanceBefore, managerEthBalanceAfter);
        assertEq(managerWethBalanceBefore, managerWethBalanceAfter);
    }

    function test_revertAddLiquidity() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook),
                IHooks.beforeAddLiquidity.selector,
                abi.encodeWithSelector(BaseTokenWrapperHook.LiquidityNotAllowed.selector),
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

    function test_revertInvalidPoolInitialization() public {
        // Try to initialize with non-zero fee
        PoolKey memory invalidKey = PoolKey({
            currency0: CurrencyLibrary.ADDRESS_ZERO,
            currency1: Currency.wrap(address(weth)),
            fee: 3000, // Invalid: must be 0
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });

        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook),
                IHooks.beforeInitialize.selector,
                abi.encodeWithSelector(BaseTokenWrapperHook.InvalidPoolFee.selector),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        manager.initialize(invalidKey, initSqrtPriceX96);

        // Try to initialize with wrong token pair
        MockERC20 randomToken = new MockERC20("Random", "RND", 18);
        // sort tokens
        (Currency currency0, Currency currency1) = address(randomToken) < address(weth)
            ? (Currency.wrap(address(randomToken)), Currency.wrap(address(weth)))
            : (Currency.wrap(address(weth)), Currency.wrap(address(randomToken)));
        invalidKey =
            PoolKey({currency0: currency0, currency1: currency1, fee: 0, tickSpacing: 60, hooks: IHooks(address(hook))});

        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook),
                IHooks.beforeInitialize.selector,
                abi.encodeWithSelector(BaseTokenWrapperHook.InvalidPoolToken.selector),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        manager.initialize(invalidKey, initSqrtPriceX96);
    }

    // add some unrelated ETH and WETH liquidity that the hook can use
    function _addUnrelatedLiquidity() internal {
        // Create a hookless pool key for ETH/WETH
        PoolKey memory unrelatedPoolKey = PoolKey({
            currency0: CurrencyLibrary.ADDRESS_ZERO,
            currency1: Currency.wrap(address(weth)),
            fee: 100, // Must be 0 for wrapper pools
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });

        manager.initialize(unrelatedPoolKey, uint160(TickMath.getSqrtPriceAtTick(0)));

        vm.deal(address(this), 100 ether);
        deal(address(weth), address(this), 100 ether);
        weth.approve(address(modifyLiquidityRouter), type(uint256).max);
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
