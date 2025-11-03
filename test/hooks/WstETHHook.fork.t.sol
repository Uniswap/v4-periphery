// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
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
import {WstETHRoutingHook} from "../../src/hooks/WstETHRoutingHook.sol";
import {IWstETH} from "../../src/interfaces/external/IWstETH.sol";
import {TestRouter} from "../shared/TestRouter.sol";
import {IV4Quoter} from "../../src/interfaces/IV4Quoter.sol";
import {Deploy} from "../shared/Deploy.sol";

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
    WstETHRoutingHook public hookSim;
    IWstETH public wstETH;
    IERC20 public stETH;
    PoolKey poolKey;
    PoolKey poolKeySim;
    TestRouter public router;
    uint160 initSqrtPriceX96;
    IV4Quoter quoter;

    // Test user
    address alice = makeAddr("alice");

    bool forked;

    function setUp() public {
        try vm.envString("INFURA_API_KEY") returns (string memory) {
            console2.log("Forked Ethereum mainnet");
            // Fork mainnet at a specific block for consistency
            vm.createSelectFork(vm.rpcUrl("mainnet"), 21_900_000);

            deployFreshManagerAndRouters();
            // replace manager with the real mainnet manager
            manager = IPoolManager(0x000000000004444c5dc75cB358380D2e3dE08A90);
            router = new TestRouter(manager);

            // Use real mainnet contracts
            wstETH = IWstETH(WSTETH);
            vm.label(address(wstETH), "wstETH");
            stETH = IERC20(STETH);
            vm.label(address(stETH), "stETH");

            // Deploy WstETH hook
            hook = WstETHHook(
                payable(address(
                        uint160(
                            type(uint160).max & clearAllHookPermissionsMask | Hooks.BEFORE_SWAP_FLAG
                                | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
                                | Hooks.BEFORE_INITIALIZE_FLAG
                        )
                    ))
            );
            hookSim = WstETHRoutingHook(
                payable(address(
                        uint160(
                            type(uint160).max & clearAllHookPermissionsMask | Hooks.BEFORE_SWAP_FLAG
                                | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
                                | Hooks.BEFORE_INITIALIZE_FLAG
                        ) & (type(uint160).max - 2 ** 156)
                    ))
            );
            deployCodeTo("WstETHHook", abi.encode(manager, wstETH), address(hook));
            deployCodeTo("WstETHRoutingHook", abi.encode(manager, wstETH), address(hookSim));
            quoter = Deploy.v4Quoter(address(manager), hex"00");

            // Create pool key for wstETH/stETH (wstETH has lower address)
            poolKey = PoolKey({
                currency0: Currency.wrap(address(wstETH)),
                currency1: Currency.wrap(address(stETH)),
                fee: 0,
                tickSpacing: 60,
                hooks: IHooks(address(hook))
            });
            poolKeySim = PoolKey({
                currency0: Currency.wrap(address(wstETH)),
                currency1: Currency.wrap(address(stETH)),
                fee: 0,
                tickSpacing: 60,
                hooks: IHooks(address(hookSim))
            });

            // Initialize pool at current exchange rate
            manager.initialize(poolKey, SQRT_PRICE_1_1);
            manager.initialize(poolKeySim, SQRT_PRICE_1_1);

            // Get tokens from whales and set up approvals
            vm.startPrank(STETH_WHALE);
            uint256 stethAmount = 100 ether;
            stETH.transfer(alice, stethAmount);
            vm.stopPrank();

            vm.startPrank(WSTETH_WHALE);
            uint256 wstethAmount = 100 ether;
            IERC20(WSTETH).transfer(alice, wstethAmount);
            vm.stopPrank();

            // Approve tokens
            vm.startPrank(alice);
            stETH.approve(address(router), type(uint256).max);
            IERC20(WSTETH).approve(address(router), type(uint256).max);
            vm.stopPrank();
            forked = true;
        } catch {
            console2.log(
                "Skipping forked tests, no infura key found. Add INFURA_API_KEY env var to .env to run forked tests."
            );
        }
    }

    modifier onlyForked() {
        if (forked) {
            console2.log("running forked test");
            _;
            return;
        }
        console2.log("skipping forked test");
    }

    function test_fork_wrap_exactInput(uint256 amount, uint256 dustStEth) public onlyForked {
        uint256 wrapAmount = bound(amount, 0.1 ether, 10 ether);
        dustStEth = bound(dustStEth, 1, 0.1 ether - 1);
        vm.prank(STETH_WHALE);
        stETH.transfer(address(manager), dustStEth);

        uint256 expectedOutput = wstETH.getWstETHByStETH(wrapAmount);

        // quoting the swap with the WstETHHook should revert
        vm.expectRevert();
        quoter.quoteExactInputSingle(
            IV4Quoter.QuoteExactSingleParams({
                poolKey: poolKey, zeroForOne: false, exactAmount: uint128(wrapAmount), hookData: ""
            })
        );

        // quoting the swap with the WstETHRoutingHook should not revert
        (uint256 quotedAmountOut,) = quoter.quoteExactInputSingle(
            IV4Quoter.QuoteExactSingleParams({
                poolKey: poolKeySim, zeroForOne: false, exactAmount: uint128(wrapAmount), hookData: ""
            })
        );

        vm.startPrank(alice);
        uint256 aliceStethBefore = stETH.balanceOf(alice);
        uint256 aliceWstethBefore = IERC20(WSTETH).balanceOf(alice);

        router.swap(
            poolKey,
            SwapParams({
                zeroForOne: false, // wstETH (0) to stETH (1)
                amountSpecified: -int256(wrapAmount),
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            ""
        );

        vm.stopPrank();

        uint256 actualAmountOut = IERC20(WSTETH).balanceOf(alice) - aliceWstethBefore;
        assertApproxEqAbs(quotedAmountOut, actualAmountOut, 2, "Quoted amount should match the actual amount received");

        assertApproxEqAbs(aliceStethBefore - stETH.balanceOf(alice), wrapAmount, 2, "Incorrect stETH spent");
        assertApproxEqAbs(actualAmountOut, expectedOutput, 2, "Incorrect wstETH received");
    }

    function test_fork_unwrap_exactInput(uint256 amount, uint256 dustStEth) public onlyForked {
        uint256 unwrapAmount = (bound(amount, 0.1 ether, 10 ether));
        dustStEth = bound(dustStEth, 1, 10 ether);
        vm.prank(STETH_WHALE);
        stETH.transfer(address(manager), dustStEth);

        uint256 expectedOutput = wstETH.getStETHByWstETH(unwrapAmount);

        vm.startPrank(alice);
        uint256 aliceStethBefore = stETH.balanceOf(alice);
        uint256 aliceWstethBefore = IERC20(WSTETH).balanceOf(alice);

        router.swap(
            poolKey,
            SwapParams({
                zeroForOne: true, // stETH (1) to wstETH (0)
                amountSpecified: -int256(unwrapAmount),
                sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
            }),
            ""
        );

        vm.stopPrank();

        // quoting the swap with the WstETHHook should not revert
        (uint256 quotedAmountOut,) = quoter.quoteExactInputSingle(
            IV4Quoter.QuoteExactSingleParams({
                poolKey: poolKey, zeroForOne: true, exactAmount: uint128(unwrapAmount), hookData: ""
            })
        );

        // quoting the swap with the WstETHRoutingHook should not revert
        (uint256 quotedAmountOutSim,) = quoter.quoteExactInputSingle(
            IV4Quoter.QuoteExactSingleParams({
                poolKey: poolKeySim, zeroForOne: true, exactAmount: uint128(unwrapAmount), hookData: ""
            })
        );

        assertEq(quotedAmountOut, quotedAmountOutSim, "Quotes from WstETHHook and WstETHRoutingHook should match");

        uint256 actualAmountOut = stETH.balanceOf(alice) - aliceStethBefore;
        // transfer from pool manager to alice can incur a small amount of rounding error
        assertApproxEqAbs(
            quotedAmountOutSim, actualAmountOut, 3, "Quoted amount should match the actual amount received"
        );

        assertApproxEqAbs(actualAmountOut, expectedOutput, 3, "Incorrect stETH received");
        assertEq(aliceWstethBefore - IERC20(WSTETH).balanceOf(alice), unwrapAmount, "Incorrect wstETH spent");
    }

    function test_fork_wrap_exactOutput() public onlyForked {
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
            SwapParams({
                zeroForOne: false, // wstETH (0) to stETH (1)
                amountSpecified: int256(wrapAmount),
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            ""
        );

        vm.stopPrank();
    }

    function test_fork_unwrap_exactOutput() public onlyForked {
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
            SwapParams({
                zeroForOne: true, // stETH (1) to wstETH (0)
                amountSpecified: int256(unwrapAmount),
                sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
            }),
            ""
        );

        vm.stopPrank();
    }
}
