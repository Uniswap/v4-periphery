// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {BaseTokenWrapperHook} from "../../src/base/hooks/BaseTokenWrapperHook.sol";
import {WstETHHook} from "../../src/hooks/WstETHHook.sol";
import {IWstETH} from "../../src/interfaces/external/IWstETH.sol";
import {TestRouter} from "../shared/TestRouter.sol";

contract WstETHHookForkTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    // Mainnet addresses
    address constant WSTETH = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;
    address constant STETH = 0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84;
    // Large holders from etherscan
    address constant STETH_WHALE = 0x1982b2F5814301d4e9a8b0201555376e62F82428;
    address constant WSTETH_WHALE = 0x10CD5fbe1b404B7E19Ef964B63939907bdaf42E2;

    WstETHHook public hook;
    IWstETH public wstETH;
    IERC20 public stETH;
    PoolKey poolKey;
    TestRouter public router;
    uint160 initSqrtPriceX96;

    // Test user
    address alice = makeAddr("alice");

    function setUp() public {
        // Fork mainnet at a specific block for consistency
        vm.createSelectFork(vm.rpcUrl("mainnet"), 21_900_000);

        deployFreshManagerAndRouters();
        router = new TestRouter(manager);

        // Use real mainnet contracts
        wstETH = IWstETH(WSTETH);
        vm.label(address(wstETH), "wstETH");
        stETH = IERC20(STETH);
        vm.label(address(stETH), "stETH");

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

        // Create pool key for wstETH/stETH (wstETH has lower address)
        poolKey = PoolKey({
            currency0: Currency.wrap(address(wstETH)),
            currency1: Currency.wrap(address(stETH)),
            fee: 0,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });

        // Initialize pool at current exchange rate
        manager.initialize(poolKey, SQRT_PRICE_1_1);

        // Get tokens from whales and set up approvals
        vm.startPrank(STETH_WHALE);
        uint256 stethAmount = 100 ether;
        stETH.transfer(alice, stethAmount);
        stETH.transfer(address(manager), 1000 ether);
        vm.stopPrank();

        vm.startPrank(WSTETH_WHALE);
        uint256 wstethAmount = 100 ether;
        IERC20(WSTETH).transfer(alice, wstethAmount);
        IERC20(WSTETH).transfer(address(manager), 1000 ether);
        vm.stopPrank();

        // Approve tokens
        vm.startPrank(alice);
        stETH.approve(address(router), type(uint256).max);
        IERC20(WSTETH).approve(address(router), type(uint256).max);
        vm.stopPrank();
    }

    function test_fork_wrap_exactInput() public {
        uint256 wrapAmount = 10 ether;
        uint256 expectedOutput = wstETH.getWstETHByStETH(wrapAmount);

        vm.startPrank(alice);
        uint256 aliceStethBefore = stETH.balanceOf(alice);
        uint256 aliceWstethBefore = IERC20(WSTETH).balanceOf(alice);

        router.swap(
            poolKey,
            IPoolManager.SwapParams({
                zeroForOne: false, // wstETH (0) to stETH (1)
                amountSpecified: -int256(wrapAmount),
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            ""
        );

        vm.stopPrank();

        assertApproxEqAbs(aliceStethBefore - stETH.balanceOf(alice), wrapAmount, 2, "Incorrect stETH spent");
        assertApproxEqAbs(
            IERC20(WSTETH).balanceOf(alice) - aliceWstethBefore, expectedOutput, 2, "Incorrect wstETH received"
        );
    }

    function test_fork_unwrap_exactInput() public {
        uint256 unwrapAmount = 10 ether;
        uint256 expectedOutput = wstETH.getStETHByWstETH(unwrapAmount);

        vm.startPrank(alice);
        uint256 aliceStethBefore = stETH.balanceOf(alice);
        uint256 aliceWstethBefore = IERC20(WSTETH).balanceOf(alice);

        router.swap(
            poolKey,
            IPoolManager.SwapParams({
                zeroForOne: true, // stETH (1) to wstETH (0)
                amountSpecified: -int256(unwrapAmount),
                sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
            }),
            ""
        );

        vm.stopPrank();

        assertApproxEqAbs(stETH.balanceOf(alice) - aliceStethBefore, expectedOutput, 1, "Incorrect stETH received");
        assertEq(aliceWstethBefore - IERC20(WSTETH).balanceOf(alice), unwrapAmount, "Incorrect wstETH spent");
    }

    function test_fork_wrap_exactOutput() public {
        uint256 wrapAmount = 10 ether;

        vm.startPrank(alice);

        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook),
                IHooks.beforeSwap.selector,
                abi.encodeWithSelector(BaseTokenWrapperHook.ExactOutputNotSupported.selector),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        router.swap(
            poolKey,
            IPoolManager.SwapParams({
                zeroForOne: false, // wstETH (0) to stETH (1)
                amountSpecified: int256(wrapAmount),
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            ""
        );

        vm.stopPrank();
    }

    function test_fork_unwrap_exactOutput() public {
        uint256 unwrapAmount = 10 ether;

        vm.startPrank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook),
                IHooks.beforeSwap.selector,
                abi.encodeWithSelector(BaseTokenWrapperHook.ExactOutputNotSupported.selector),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        router.swap(
            poolKey,
            IPoolManager.SwapParams({
                zeroForOne: true, // stETH (1) to wstETH (0)
                amountSpecified: int256(unwrapAmount),
                sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
            }),
            ""
        );

        vm.stopPrank();
    }
}
