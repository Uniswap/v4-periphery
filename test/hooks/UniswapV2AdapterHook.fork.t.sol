// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {WETH} from "solmate/src/tokens/WETH.sol";
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
import {UniswapV2AdapterHook} from "../../src/hooks/UniswapV2AdapterHook.sol";
import {IWstETH} from "../../src/interfaces/external/IWstETH.sol";
import {TestRouter} from "../shared/TestRouter.sol";
import {IV4Quoter} from "../../src/interfaces/IV4Quoter.sol";
import {Deploy} from "../shared/Deploy.sol";

contract UniswapV2AdapterHookForkTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    // Mainnet addresses
    IERC20 constant usdc = IERC20(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);
    WETH constant weth = WETH(payable(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2));
    address constant UNISWAP_V2_FACTORY = 0x5C69bEe701ef814a2B6a3EDD4B1652CB9cc5aA6f;

    UniswapV2AdapterHook public hook;
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

            hook = UniswapV2AdapterHook(
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
            deployCodeTo("UniswapV2AdapterHook", abi.encode(manager, UNISWAP_V2_FACTORY), address(hook));
            quoter = Deploy.v4Quoter(address(manager), hex"00");

            // Create pool key for wstETH/stETH (wstETH has lower address)
            poolKey = PoolKey({
                currency0: Currency.wrap(address(usdc)),
                currency1: Currency.wrap(address(weth)),
                fee: 3000,
                tickSpacing: 1,
                hooks: IHooks(address(hook))
            });

            // Initialize pool at current exchange rate
            manager.initialize(poolKey, SQRT_PRICE_1_1);

            // Get tokens from whales and set up approvals
            deal(address(weth), alice, 100 ether);
            deal(address(usdc), alice, 100 ether);
            deal(address(weth), address(manager), 100 ether);
            deal(address(usdc), address(manager), 100 ether);

            // Approve tokens
            vm.startPrank(alice);
            weth.approve(address(router), type(uint256).max);
            usdc.approve(address(router), type(uint256).max);
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

    function test_fork_swap_exactInput_weth() public onlyForked {
        uint256 amountIn = 1 ether;

        vm.startPrank(alice);
        uint256 aliceWethBefore = weth.balanceOf(alice);
        uint256 aliceUsdcBefore = usdc.balanceOf(alice);

        router.swap(
            poolKey,
            SwapParams({
                zeroForOne: false, // weth (1) to usdc (0)
                amountSpecified: -int256(amountIn),
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            ""
        );
        vm.snapshotGasLastCall("UniswapV2Adapter_exactInput_weth");

        vm.stopPrank();

        uint256 actualAmountOut = usdc.balanceOf(alice) - aliceUsdcBefore;
        assertEq(actualAmountOut, 2678967467, "Quoted amount should match the actual amount received");
        assertEq(aliceWethBefore - weth.balanceOf(alice), amountIn, "Incorrect input spent");
    }

    function test_fork_swap_exactInput_usdc() public onlyForked {
        uint256 amountIn = 1000_000000; // 1000 USDC

        vm.startPrank(alice);
        uint256 aliceWethBefore = weth.balanceOf(alice);
        uint256 aliceUsdcBefore = usdc.balanceOf(alice);

        router.swap(
            poolKey,
            SwapParams({
                zeroForOne: true, // usdc (0) for weth (1)
                amountSpecified: -int256(amountIn),
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            ""
        );
        vm.snapshotGasLastCall("UniswapV2Adapter_exactInput_usdc");

        vm.stopPrank();

        uint256 actualAmountOut = weth.balanceOf(alice) - aliceWethBefore;
        assertEq(actualAmountOut, 370978046636824314, "Quoted amount should match the actual amount received");
        assertEq(aliceUsdcBefore - usdc.balanceOf(alice), amountIn, "Incorrect input spent");
    }

    function test_fork_swap_exactOutput_weth() public onlyForked {
        uint256 amountOut = 1000_000000; // 1000 USDC

        vm.startPrank(alice);
        uint256 aliceWethBefore = weth.balanceOf(alice);
        uint256 aliceUsdcBefore = usdc.balanceOf(alice);

        router.swap(
            poolKey,
            SwapParams({
                zeroForOne: false, // weth (1) to usdc (0)
                amountSpecified: int256(amountOut),
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            ""
        );
        vm.snapshotGasLastCall("UniswapV2Adapter_exactOutput_weth");

        vm.stopPrank();

        uint256 actualAmountOut = usdc.balanceOf(alice) - aliceUsdcBefore;
        assertEq(actualAmountOut, amountOut, "Quoted amount should match the actual amount received");
        assertEq(aliceWethBefore - weth.balanceOf(alice), 373248830169735674, "Incorrect input spent");
    }

    function test_fork_swap_exactOutput_usdc() public onlyForked {
        uint256 amountOut = 1 ether;

        vm.startPrank(alice);
        uint256 aliceWethBefore = weth.balanceOf(alice);
        uint256 aliceUsdcBefore = usdc.balanceOf(alice);

        router.swap(
            poolKey,
            SwapParams({
                zeroForOne: true, // usdc (0) for weth (1)
                amountSpecified: int256(amountOut),
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            ""
        );
        vm.snapshotGasLastCall("UniswapV2Adapter_exactOutput_usdc");

        vm.stopPrank();

        uint256 actualAmountOut = weth.balanceOf(alice) - aliceWethBefore;
        assertEq(actualAmountOut, amountOut, "Quoted amount should match the actual amount received");
        assertEq(aliceUsdcBefore - usdc.balanceOf(alice), 2695790431, "Incorrect input spent");
    }
}
