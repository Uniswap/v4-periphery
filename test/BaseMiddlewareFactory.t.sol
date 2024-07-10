// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

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
import {HooksCounter} from "./middleware-implementations/HooksCounter.sol";
import {BaseImplementation} from "./../contracts/middleware/BaseImplementation.sol";

contract BaseMiddlewareFactoryTest is Test, Deployers {
    HookEnabledSwapRouter router;
    TestERC20 token0;
    TestERC20 token1;

    BaseMiddlewareFactory factory;
    HooksCounter hooksCounter;

    address middleware;

    function setUp() public {
        deployFreshManagerAndRouters();
        (currency0, currency1) = deployMintAndApprove2Currencies();

        router = new HookEnabledSwapRouter(manager);
        token0 = TestERC20(Currency.unwrap(currency0));
        token1 = TestERC20(Currency.unwrap(currency1));

        factory = new BaseMiddlewareFactory(manager);
        hooksCounter = new HooksCounter(manager, address(factory));

        token0.approve(address(router), type(uint256).max);
        token1.approve(address(router), type(uint256).max);

        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
                | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
                | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG | Hooks.BEFORE_DONATE_FLAG | Hooks.AFTER_DONATE_FLAG
        );

        (address hookAddress, bytes32 salt) = HookMiner.find(
            address(factory),
            flags,
            type(BaseMiddleware).creationCode,
            abi.encode(address(manager), address(hooksCounter))
        );
        middleware = factory.createMiddleware(address(hooksCounter), salt);
        assertEq(hookAddress, middleware);
    }

    function testRevertOnAlreadyInitialized() public {
        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
                | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
                | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG | Hooks.BEFORE_DONATE_FLAG | Hooks.AFTER_DONATE_FLAG
        );
        (address hookAddress, bytes32 salt) = HookMiner.find(
            address(factory),
            flags,
            type(BaseMiddleware).creationCode,
            abi.encode(address(manager), address(hooksCounter))
        );
        vm.expectRevert(BaseMiddlewareFactory.AlreadyInitialized.selector);
        factory.createMiddleware(address(hooksCounter), salt);
    }

    function testRevertOnIncorrectFlags() public {
        HooksCounter hooksCounter2 = new HooksCounter(manager, address(factory));
        uint160 flags = uint160(Hooks.BEFORE_INITIALIZE_FLAG);

        (address hookAddress, bytes32 salt) = HookMiner.find(
            address(factory),
            flags,
            type(BaseMiddleware).creationCode,
            abi.encode(address(manager), address(hooksCounter2))
        );
        address implementation = address(hooksCounter2);
        vm.expectRevert(abi.encodePacked(bytes16(Hooks.HookAddressNotValid.selector), hookAddress));
        factory.createMiddleware(implementation, salt);
    }

    function testRevertOnIncorrectFlagsMined() public {
        HooksCounter hooksCounter2 = new HooksCounter(manager, address(factory));
        address implementation = address(hooksCounter2);
        vm.expectRevert(); // HookAddressNotValid
        factory.createMiddleware(implementation, bytes32("who needs to mine a salt?"));
    }

    function testRevertOnIncorrectCaller() public {
        vm.expectRevert(BaseImplementation.NotMiddleware.selector);
        hooksCounter.afterDonate(address(this), key, 0, 0, ZERO_BYTES);
    }

    function testCounters() public {
        (PoolKey memory key, PoolId id) =
            initPoolAndAddLiquidity(currency0, currency1, IHooks(middleware), 3000, SQRT_PRICE_1_1, ZERO_BYTES);

        assertEq(hooksCounter.beforeInitializeCount(id), 1);
        assertEq(hooksCounter.afterInitializeCount(id), 1);
        assertEq(hooksCounter.beforeSwapCount(id), 0);
        assertEq(hooksCounter.afterSwapCount(id), 0);
        assertEq(hooksCounter.beforeAddLiquidityCount(id), 1);
        assertEq(hooksCounter.afterAddLiquidityCount(id), 1);
        assertEq(hooksCounter.beforeRemoveLiquidityCount(id), 0);
        assertEq(hooksCounter.afterRemoveLiquidityCount(id), 0);
        assertEq(hooksCounter.beforeDonateCount(id), 0);
        assertEq(hooksCounter.afterDonateCount(id), 0);

        assertEq(hooksCounter.lastHookData(), ZERO_BYTES);
        swap(key, true, 1, bytes("hi"));
        assertEq(hooksCounter.lastHookData(), bytes("hi"));
        assertEq(hooksCounter.beforeSwapCount(id), 1);
        assertEq(hooksCounter.afterSwapCount(id), 1);
    }
}
