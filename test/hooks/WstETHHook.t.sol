// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {ERC20} from "solmate/src/tokens/ERC20.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {BaseTokenWrapperHook} from "../../src/base/hooks/BaseTokenWrapperHook.sol";
import {WstETHHook} from "../../src/hooks/WstETHHook.sol";
import {IWstETH} from "../../src/interfaces/external/IWstETH.sol";
import {MockWstETH} from "../mocks/MockWstETH.sol";
import {TestRouter} from "../shared/TestRouter.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

contract WstETHHookTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    WstETHHook public hook;
    MockWstETH public wstETH;
    MockERC20 public stETH;
    TestRouter public router;
    PoolKey poolKey;
    uint160 initSqrtPriceX96;

    // Users
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    event Transfer(address indexed from, address indexed to, uint256 amount);

    function setUp() public {
        deployFreshManagerAndRouters();
        router = new TestRouter(manager);

        // Deploy mock stETH and wstETH
        stETH = new MockERC20("Liquid staked Ether", "stETH", 18);
        wstETH = new MockWstETH(address(stETH));

        // Deploy WstETH hook
        hook = WstETHHook(
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
        deployCodeTo("WstETHHook", abi.encode(manager, wstETH), address(hook));

        // Create pool key for stETH/wstETH
        poolKey = PoolKey({
            currency0: Currency.wrap(address(stETH)),
            currency1: Currency.wrap(address(wstETH)),
            fee: 0, // Must be 0 for wrapper pools
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });

        // Initialize pool at 1:1 price
        initSqrtPriceX96 = uint160(TickMath.getSqrtPriceAtTick(0));
        manager.initialize(poolKey, initSqrtPriceX96);

        // Give users some tokens
        stETH.mint(alice, 100 ether);
        stETH.mint(bob, 100 ether);
        stETH.mint(address(this), 200 ether);
        stETH.mint(address(wstETH), 200 ether);

        wstETH.mint(alice, 100 ether);
        wstETH.mint(bob, 100 ether);
        wstETH.mint(address(this), 200 ether);

        _addUnrelatedLiquidity();
    }

    function test_initialization() public view {
        assertEq(address(hook.wstETH()), address(wstETH));
        assertEq(Currency.unwrap(hook.wrapperCurrency()), address(wstETH));
        assertEq(Currency.unwrap(hook.underlyingCurrency()), address(stETH));
    }

    function test_wrap_exactInput() public {
        uint256 wrapAmount = 1 ether;
        uint256 expectedOutput = wstETH.getWstETHByStETH(wrapAmount);

        vm.startPrank(alice);
        stETH.approve(address(router), type(uint256).max);

        uint256 aliceStethBefore = stETH.balanceOf(alice);
        uint256 aliceWstethBefore = wstETH.balanceOf(alice);
        uint256 managerStethBefore = stETH.balanceOf(address(manager));
        uint256 managerWstethBefore = wstETH.balanceOf(address(manager));

        router.swap(
            poolKey,
            SwapParams({
                zeroForOne: true, // stETH (0) to wstETH (1)
                amountSpecified: -int256(wrapAmount),
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            ""
        );

        vm.stopPrank();

        assertEq(aliceStethBefore - stETH.balanceOf(alice), wrapAmount);
        assertEq(wstETH.balanceOf(alice) - aliceWstethBefore, expectedOutput);
        assertEq(managerStethBefore, stETH.balanceOf(address(manager)));
        assertEq(managerWstethBefore, wstETH.balanceOf(address(manager)));
    }

    function test_unwrap_exactInput() public {
        uint256 unwrapAmount = 1 ether;
        uint256 expectedOutput = wstETH.getStETHByWstETH(unwrapAmount);

        vm.startPrank(alice);
        wstETH.approve(address(router), type(uint256).max);

        uint256 aliceStethBefore = stETH.balanceOf(alice);
        uint256 aliceWstethBefore = wstETH.balanceOf(alice);
        uint256 managerStethBefore = stETH.balanceOf(address(manager));
        uint256 managerWstethBefore = wstETH.balanceOf(address(manager));

        router.swap(
            poolKey,
            SwapParams({
                zeroForOne: false, // wstETH (1) to stETH (0)
                amountSpecified: -int256(unwrapAmount),
                sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
            }),
            ""
        );

        vm.stopPrank();

        assertEq(stETH.balanceOf(alice) - aliceStethBefore, expectedOutput);
        assertEq(aliceWstethBefore - wstETH.balanceOf(alice), unwrapAmount);
        assertEq(managerStethBefore, stETH.balanceOf(address(manager)));
        assertEq(managerWstethBefore, wstETH.balanceOf(address(manager)));
    }

    function test_revert_wrap_exactOutput() public {
        vm.startPrank(alice);
        wstETH.approve(address(router), type(uint256).max);
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook),
                IHooks.beforeSwap.selector,
                abi.encodeWithSelector(BaseTokenWrapperHook.ExactOutputNotSupported.selector),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        router.swap(poolKey, SwapParams({zeroForOne: true, amountSpecified: 1 ether, sqrtPriceLimitX96: 0}), "");
    }

    function test_revert_unwrap_exactOutput() public {
        vm.startPrank(alice);
        stETH.approve(address(router), type(uint256).max);
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook),
                IHooks.beforeSwap.selector,
                abi.encodeWithSelector(BaseTokenWrapperHook.ExactOutputNotSupported.selector),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        router.swap(poolKey, SwapParams({zeroForOne: false, amountSpecified: 1 ether, sqrtPriceLimitX96: 0}), "");
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
            ModifyLiquidityParams({tickLower: -120, tickUpper: 120, liquidityDelta: 1000e18, salt: bytes32(0)}),
            ""
        );
    }

    function test_revertInvalidPoolInitialization() public {
        // Try to initialize with non-zero fee
        PoolKey memory invalidKey = PoolKey({
            currency0: Currency.wrap(address(stETH)),
            currency1: Currency.wrap(address(wstETH)),
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
        (Currency currency0, Currency currency1) = address(randomToken) < address(wstETH)
            ? (Currency.wrap(address(randomToken)), Currency.wrap(address(wstETH)))
            : (Currency.wrap(address(wstETH)), Currency.wrap(address(randomToken)));
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

    function _addUnrelatedLiquidity() internal {
        // Create a hookless pool key for stETH/wstETH
        PoolKey memory unrelatedPoolKey = PoolKey({
            currency0: Currency.wrap(address(stETH)),
            currency1: Currency.wrap(address(wstETH)),
            fee: 100,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });

        manager.initialize(unrelatedPoolKey, uint160(TickMath.getSqrtPriceAtTick(0)));

        stETH.approve(address(modifyLiquidityRouter), type(uint256).max);
        wstETH.approve(address(modifyLiquidityRouter), type(uint256).max);
        modifyLiquidityRouter.modifyLiquidity(
            unrelatedPoolKey,
            ModifyLiquidityParams({tickLower: -120, tickUpper: 120, liquidityDelta: 1000e18, salt: bytes32(0)}),
            ""
        );
    }
}
