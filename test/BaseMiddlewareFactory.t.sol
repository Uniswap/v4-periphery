// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {TestERC20} from "@uniswap/v4-core/src/test/TestERC20.sol";
import {CurrencyLibrary, Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {HookEnabledSwapRouter} from "./utils/HookEnabledSwapRouter.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {console} from "../../../lib/forge-std/src/console.sol";
import {BaseMiddleware} from "../contracts/middleware/BaseMiddleware.sol";
import {BaseMiddlewareFactory} from "./../contracts/middleware/BaseMiddlewareFactory.sol";
import {HookMiner} from "./utils/HookMiner.sol";
import {Counter} from "./middleware/Counter.sol";
import {SafeCallback} from "./../contracts/base/SafeCallback.sol";

contract BaseMiddlewareFactoryTest is Test, Deployers {
    HookEnabledSwapRouter router;
    TestERC20 token0;
    TestERC20 token1;

    BaseMiddlewareFactory factory;
    Counter counter;

    address middleware;

    function setUp() public {
        deployFreshManagerAndRouters();
        (currency0, currency1) = deployMintAndApprove2Currencies();

        router = new HookEnabledSwapRouter(manager);
        token0 = TestERC20(Currency.unwrap(currency0));
        token1 = TestERC20(Currency.unwrap(currency1));

        factory = new BaseMiddlewareFactory(manager);
        counter = new Counter(manager);

        token0.approve(address(router), type(uint256).max);
        token1.approve(address(router), type(uint256).max);

        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
                | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
                | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG | Hooks.BEFORE_DONATE_FLAG | Hooks.AFTER_DONATE_FLAG
        );

        (address hookAddress, bytes32 salt) = HookMiner.find(
            address(factory), flags, type(BaseMiddleware).creationCode, abi.encode(address(manager), address(counter))
        );
        middleware = factory.createMiddleware(address(counter), salt);
        assertEq(hookAddress, middleware);
    }

    function testRevertOnSameDeployment() public {
        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
                | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
                | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG | Hooks.BEFORE_DONATE_FLAG | Hooks.AFTER_DONATE_FLAG
        );
        (address hookAddress, bytes32 salt) = HookMiner.find(
            address(factory), flags, type(BaseMiddleware).creationCode, abi.encode(address(manager), address(counter))
        );
        factory.createMiddleware(address(counter), salt);
        // second deployment should revert
        vm.expectRevert(bytes(""));
        factory.createMiddleware(address(counter), salt);
    }

    function testRevertOnIncorrectFlags() public {
        Counter counter2 = new Counter(manager);
        uint160 flags = uint160(Hooks.BEFORE_INITIALIZE_FLAG);

        (address hookAddress, bytes32 salt) = HookMiner.find(
            address(factory), flags, type(BaseMiddleware).creationCode, abi.encode(address(manager), address(counter2))
        );
        address implementation = address(counter2);
        vm.expectRevert(abi.encodePacked(bytes16(Hooks.HookAddressNotValid.selector), hookAddress));
        factory.createMiddleware(implementation, salt);
    }

    function testRevertOnIncorrectFlagsMined() public {
        Counter counter2 = new Counter(manager);
        address implementation = address(counter2);
        vm.expectRevert(); // HookAddressNotValid
        factory.createMiddleware(implementation, bytes32("who needs to mine a salt?"));
    }

    function testRevertOnIncorrectCaller() public {
        vm.expectRevert(SafeCallback.NotManager.selector);
        counter.afterDonate(address(this), key, 0, 0, ZERO_BYTES);
    }

    function testCounters() public {
        (PoolKey memory key, PoolId id) =
            initPoolAndAddLiquidity(currency0, currency1, IHooks(middleware), 3000, SQRT_PRICE_1_1, ZERO_BYTES);

        Counter counterProxy = Counter(middleware);
        assertEq(counterProxy.beforeInitializeCount(id), 1);
        assertEq(counterProxy.afterInitializeCount(id), 1);
        assertEq(counterProxy.beforeSwapCount(id), 0);
        assertEq(counterProxy.afterSwapCount(id), 0);
        assertEq(counterProxy.beforeAddLiquidityCount(id), 1);
        assertEq(counterProxy.afterAddLiquidityCount(id), 1);
        assertEq(counterProxy.beforeRemoveLiquidityCount(id), 0);
        assertEq(counterProxy.afterRemoveLiquidityCount(id), 0);
        assertEq(counterProxy.beforeDonateCount(id), 0);
        assertEq(counterProxy.afterDonateCount(id), 0);

        assertEq(counterProxy.lastHookData(), ZERO_BYTES);
        swap(key, true, 1, bytes("hi"));
        assertEq(counterProxy.lastHookData(), bytes("hi"));
        assertEq(counterProxy.beforeSwapCount(id), 1);
        assertEq(counterProxy.afterSwapCount(id), 1);

        // counter does not store data itself
        assertEq(counter.lastHookData(), bytes(""));
        assertEq(counter.beforeSwapCount(id), 0);
        assertEq(counter.afterSwapCount(id), 0);
    }
}
