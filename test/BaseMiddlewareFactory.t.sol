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
import {console} from "../../../lib/v4-core/lib/forge-std/src/console.sol";
import {BaseMiddleware} from "./../src/middleware/BaseMiddleware.sol";
import {BaseMiddlewareImplementation} from "./middleware/BaseMiddlewareImplemenation.sol";
import {BaseMiddlewareFactoryImplementation} from "./middleware/BaseMiddlewareFactoryImplementation.sol";
import {HookMiner} from "./utils/HookMiner.sol";
import {HooksCounter} from "./middleware/HooksCounter.sol";
import {SafeCallback} from "./../src/base/SafeCallback.sol";

contract BaseMiddlewareFactoryTest is Test, Deployers {
    HookEnabledSwapRouter router;
    TestERC20 token0;
    TestERC20 token1;

    BaseMiddlewareFactoryImplementation factory;
    HooksCounter hookscounter;
    address middleware;

    uint160 HOOKSCOUNTER_FLAGS = uint160(
        Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
            | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
            | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG | Hooks.BEFORE_DONATE_FLAG | Hooks.AFTER_DONATE_FLAG
    );

    function setUp() public {
        deployFreshManagerAndRouters();
        (currency0, currency1) = deployMintAndApprove2Currencies();

        router = new HookEnabledSwapRouter(manager);
        token0 = TestERC20(Currency.unwrap(currency0));
        token1 = TestERC20(Currency.unwrap(currency1));

        factory = new BaseMiddlewareFactoryImplementation(manager);
        hookscounter = HooksCounter(address(HOOKSCOUNTER_FLAGS));
        vm.etch(address(hookscounter), address(new HooksCounter(manager)).code);

        token0.approve(address(router), type(uint256).max);
        token1.approve(address(router), type(uint256).max);

        (address hookAddress, bytes32 salt) = HookMiner.find(
            address(factory),
            HOOKSCOUNTER_FLAGS,
            type(BaseMiddlewareImplementation).creationCode,
            abi.encode(address(manager), address(hookscounter))
        );
        middleware = factory.createMiddleware(address(hookscounter), salt);
        assertEq(hookAddress, middleware);
    }

    function testRevertOnSameDeployment() public {
        (address hookAddress, bytes32 salt) = HookMiner.find(
            address(factory),
            HOOKSCOUNTER_FLAGS,
            type(BaseMiddlewareImplementation).creationCode,
            abi.encode(address(manager), address(hookscounter))
        );
        factory.createMiddleware(address(hookscounter), salt);
        // second deployment should revert
        vm.expectRevert(ZERO_BYTES);
        factory.createMiddleware(address(hookscounter), salt);
<<<<<<< HEAD
    }

    function testRevertOnIncorrectCaller() public {
        vm.expectRevert(SafeCallback.NotPoolManager.selector);
=======
    }

    function testRevertOnIncorrectFlags() public {
        HooksCounter hookscounter2 = HooksCounter(address(HOOKSCOUNTER_FLAGS));
        vm.etch(address(hookscounter), address(new HooksCounter(manager)).code);
        uint160 incorrectFlags = uint160(Hooks.BEFORE_INITIALIZE_FLAG);

        (address hookAddress, bytes32 salt) = HookMiner.find(
            address(factory),
            incorrectFlags,
            type(BaseMiddlewareImplementation).creationCode,
            abi.encode(address(manager), address(hookscounter2))
        );
        address implementation = address(hookscounter2);
        vm.expectRevert(BaseMiddleware.FlagsMismatch.selector);
        factory.createMiddleware(implementation, salt);
    }

    function testRevertOnIncorrectFlagsMined() public {
        HooksCounter hookscounter2 = HooksCounter(address(HOOKSCOUNTER_FLAGS));
        vm.etch(address(hookscounter), address(new HooksCounter(manager)).code);
        address implementation = address(hookscounter2);
        vm.expectRevert(BaseMiddleware.FlagsMismatch.selector);
        factory.createMiddleware(implementation, bytes32("who needs to mine a salt?"));
    }

    function testRevertOnIncorrectCaller() public {
        vm.expectRevert(SafeCallback.NotManager.selector);
>>>>>>> origin/base-middleware
        hookscounter.afterDonate(address(this), key, 0, 0, ZERO_BYTES);
    }

    function testHooksCounters() public {
        (PoolKey memory key, PoolId id) =
            initPoolAndAddLiquidity(currency0, currency1, IHooks(middleware), 3000, SQRT_PRICE_1_1, ZERO_BYTES);

        HooksCounter hookscounterProxy = HooksCounter(middleware);
        assertEq(hookscounterProxy.beforeInitializeCount(id), 1);
        assertEq(hookscounterProxy.afterInitializeCount(id), 1);
        assertEq(hookscounterProxy.beforeSwapCount(id), 0);
        assertEq(hookscounterProxy.afterSwapCount(id), 0);
        assertEq(hookscounterProxy.beforeAddLiquidityCount(id), 1);
        assertEq(hookscounterProxy.afterAddLiquidityCount(id), 1);
        assertEq(hookscounterProxy.beforeRemoveLiquidityCount(id), 0);
        assertEq(hookscounterProxy.afterRemoveLiquidityCount(id), 0);
        assertEq(hookscounterProxy.beforeDonateCount(id), 0);
        assertEq(hookscounterProxy.afterDonateCount(id), 0);

        assertEq(hookscounterProxy.lastHookData(), ZERO_BYTES);
        swap(key, true, 1, bytes("hi"));
        assertEq(hookscounterProxy.lastHookData(), bytes("hi"));
        assertEq(hookscounterProxy.beforeSwapCount(id), 1);
        assertEq(hookscounterProxy.afterSwapCount(id), 1);

        // hookscounter does not store data itself
        assertEq(hookscounter.lastHookData(), ZERO_BYTES);
        assertEq(hookscounter.beforeSwapCount(id), 0);
        assertEq(hookscounter.afterSwapCount(id), 0);
    }
}
