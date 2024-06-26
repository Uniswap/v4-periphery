// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {Test} from "forge-std/Test.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {FeeTakingLite} from "./middleware/FeeTakingLite.sol";
import {MiddlewareRemove} from "../contracts/middleware/MiddlewareRemove.sol";
import {MiddlewareRemoveImplementation} from "./shared/implementation/MiddlewareRemoveImplementation.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {TestERC20} from "@uniswap/v4-core/src/test/TestERC20.sol";
import {CurrencyLibrary, Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {HookEnabledSwapRouter} from "./utils/HookEnabledSwapRouter.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {console} from "../../../lib/forge-std/src/console.sol";
import {HooksRevert} from "./middleware/HooksRevert.sol";
import {HooksOutOfGas} from "./middleware/HooksOutOfGas.sol";

contract MiddlewareRemoveTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    uint160 constant SQRT_RATIO_10_1 = 250541448375047931186413801569;

    address constant TREASURY = address(0x1234567890123456789012345678901234567890);
    uint128 private constant TOTAL_BIPS = 10000;

    HookEnabledSwapRouter router;
    TestERC20 token0;
    TestERC20 token1;
    PoolId id;

    uint160 nonce = 0;

    function setUp() public {
        deployFreshManagerAndRouters();
        (currency0, currency1) = deployMintAndApprove2Currencies();

        router = new HookEnabledSwapRouter(manager);
        token0 = TestERC20(Currency.unwrap(currency0));
        token1 = TestERC20(Currency.unwrap(currency1));

        token0.approve(address(router), type(uint256).max);
        token1.approve(address(router), type(uint256).max);
    }

    function testVarious() public {
        FeeTakingLite feeTakingLite = new FeeTakingLite(manager);
        testOn(
            address(feeTakingLite),
            uint160(Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG)
        );
        HooksRevert hooksRevert = new HooksRevert(manager);
        testOn(address(hooksRevert), uint160(Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG));
        testOn(address(hooksRevert), uint160(Hooks.AFTER_REMOVE_LIQUIDITY_FLAG));
        testOn(address(hooksRevert), uint160(Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG));
        HooksOutOfGas hooksOutOfGas = new HooksOutOfGas(manager);
        testOn(address(hooksOutOfGas), uint160(Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG));
        testOn(address(hooksOutOfGas), uint160(Hooks.AFTER_REMOVE_LIQUIDITY_FLAG));
        testOn(address(hooksOutOfGas), uint160(Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG));
    }

    // creates a middleware on an implementation
    function testOn(address implementation, uint160 flags) internal {
        MiddlewareRemove middlewareRemove = MiddlewareRemove(payable(address(nonce << 20 | flags)));
        nonce++;
        vm.record();
        MiddlewareRemoveImplementation impl =
            new MiddlewareRemoveImplementation(manager, implementation, middlewareRemove);
        (, bytes32[] memory writes) = vm.accesses(address(impl));
        vm.etch(address(middlewareRemove), address(impl).code);
        unchecked {
            for (uint256 i = 0; i < writes.length; i++) {
                bytes32 slot = writes[i];
                vm.store(address(middlewareRemove), slot, vm.load(address(impl), slot));
            }
        }
        (key, id) = initPoolAndAddLiquidity(
            currency0, currency1, IHooks(address(middlewareRemove)), 3000, SQRT_PRICE_1_1, ZERO_BYTES
        );

        removeLiquidity(currency0, currency1, IHooks(address(middlewareRemove)), 3000, SQRT_PRICE_1_1, ZERO_BYTES);
    }
}
