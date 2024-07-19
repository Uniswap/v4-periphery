// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {Test} from "forge-std/Test.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {HooksCounter} from "./middleware/HooksCounter.sol";
import {MiddlewareRemove} from "../contracts/middleware/MiddlewareRemove.sol";
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
import {MiddlewareRemoveFactory} from "./../contracts/middleware/MiddlewareRemoveFactory.sol";
import {HookMiner} from "./utils/HookMiner.sol";
import {SafeCallback} from "./../contracts/base/SafeCallback.sol";
import {FeeOnRemove} from "./middleware/FeeOnRemove.sol";
import {FrontrunRemove} from "./middleware/FrontrunRemove.sol";
import {BaseMiddleware} from "./../contracts/middleware/BaseMiddleware.sol";

contract MiddlewareRemoveFactoryTest is Test, Deployers {
    HookEnabledSwapRouter router;
    TestERC20 token0;
    TestERC20 token1;

    MiddlewareRemoveFactory factory;
    HooksCounter hookscounter;
    address middleware;

    uint160 COUNTER_FLAGS = uint160(
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

        factory = new MiddlewareRemoveFactory(manager);
        hookscounter = HooksCounter(address(COUNTER_FLAGS));
        vm.etch(address(hookscounter), address(new HooksCounter(manager)).code);

        token0.approve(address(router), type(uint256).max);
        token1.approve(address(router), type(uint256).max);

        (address hookAddress, bytes32 salt) = HookMiner.find(
            address(factory),
            COUNTER_FLAGS,
            type(MiddlewareRemove).creationCode,
            abi.encode(address(manager), address(hookscounter))
        );
        middleware = factory.createMiddleware(address(hookscounter), salt);
        assertEq(hookAddress, middleware);
    }

    function testFrontrunRemove() public {
        uint160 flags = uint160(Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG);
        FrontrunRemove frontrunRemove = FrontrunRemove(address(flags));
        FrontrunRemove impl = new FrontrunRemove(manager);
        vm.etch(address(frontrunRemove), address(impl).code);
        (, bytes32 salt) = HookMiner.find(
            address(factory),
            flags,
            type(MiddlewareRemove).creationCode,
            abi.encode(address(manager), address(frontrunRemove))
        );
        middleware = factory.createMiddleware(address(frontrunRemove), salt);
        currency0.transfer(address(frontrunRemove), 1 ether);
        currency1.transfer(address(frontrunRemove), 1 ether);
        currency0.transfer(address(middleware), 1 ether);
        currency1.transfer(address(middleware), 1 ether);

        (key,) = initPoolAndAddLiquidity(currency0, currency1, IHooks(frontrunRemove), 3000, SQRT_PRICE_1_1, ZERO_BYTES);
        uint256 initialBalance0 = token0.balanceOf(address(this));
        uint256 initialBalance1 = token1.balanceOf(address(this));
        modifyLiquidityRouter.modifyLiquidity(key, REMOVE_LIQUIDITY_PARAMS, ZERO_BYTES);
        uint256 outFrontrun0 = token0.balanceOf(address(this)) - initialBalance0;
        uint256 outFrontrun1 = token1.balanceOf(address(this)) - initialBalance1;

        IHooks noHooks = IHooks(address(0));
        (key,) = initPoolAndAddLiquidity(currency0, currency1, noHooks, 3000, SQRT_PRICE_1_1, ZERO_BYTES);
        initialBalance0 = token0.balanceOf(address(this));
        initialBalance1 = token1.balanceOf(address(this));
        modifyLiquidityRouter.modifyLiquidity(key, REMOVE_LIQUIDITY_PARAMS, ZERO_BYTES);
        uint256 outNormal0 = token0.balanceOf(address(this)) - initialBalance0;
        uint256 outNormal1 = token1.balanceOf(address(this)) - initialBalance1;

        // was frontrun
        assertTrue(outFrontrun0 > outNormal0);
        assertTrue(outFrontrun1 < outNormal1);

        (key,) = initPoolAndAddLiquidity(currency0, currency1, IHooks(middleware), 3000, SQRT_PRICE_1_1, ZERO_BYTES);
        initialBalance0 = token0.balanceOf(address(this));
        initialBalance1 = token1.balanceOf(address(this));
        modifyLiquidityRouter.modifyLiquidity(key, REMOVE_LIQUIDITY_PARAMS, ZERO_BYTES);
        uint256 out0 = token0.balanceOf(address(this)) - initialBalance0;
        uint256 out1 = token1.balanceOf(address(this)) - initialBalance1;

        // no frontrun
        assertEq(outNormal0, out0);
        assertEq(outNormal1, out1);
    }

    function testFeeOnRemove() public {
        uint160 flags = uint160(Hooks.AFTER_REMOVE_LIQUIDITY_FLAG);
        FeeOnRemove feeOnRemove = FeeOnRemove(address(flags));
        FeeOnRemove impl = new FeeOnRemove(manager);
        vm.etch(address(feeOnRemove), address(impl).code);
        (, bytes32 salt) = HookMiner.find(
            address(factory),
            flags,
            type(MiddlewareRemove).creationCode,
            abi.encode(address(manager), address(feeOnRemove))
        );
        middleware = factory.createMiddleware(address(feeOnRemove), salt);

        (key,) = initPoolAndAddLiquidity(currency0, currency1, IHooks(feeOnRemove), 3000, SQRT_PRICE_1_1, ZERO_BYTES);
        vm.expectRevert(IPoolManager.CurrencyNotSettled.selector);
        modifyLiquidityRouter.modifyLiquidity(key, REMOVE_LIQUIDITY_PARAMS, ZERO_BYTES);

        IHooks noHooks = IHooks(address(0));
        (key,) = initPoolAndAddLiquidity(currency0, currency1, noHooks, 3000, SQRT_PRICE_1_1, ZERO_BYTES);
        uint256 initialBalance0 = token0.balanceOf(address(this));
        uint256 initialBalance1 = token1.balanceOf(address(this));
        modifyLiquidityRouter.modifyLiquidity(key, REMOVE_LIQUIDITY_PARAMS, ZERO_BYTES);
        uint256 outNormal0 = token0.balanceOf(address(this)) - initialBalance0;
        uint256 outNormal1 = token1.balanceOf(address(this)) - initialBalance1;

        (key,) = initPoolAndAddLiquidity(currency0, currency1, IHooks(middleware), 3000, SQRT_PRICE_1_1, ZERO_BYTES);
        initialBalance0 = token0.balanceOf(address(this));
        initialBalance1 = token1.balanceOf(address(this));
        modifyLiquidityRouter.modifyLiquidity(key, REMOVE_LIQUIDITY_PARAMS, ZERO_BYTES);
        uint256 out0 = token0.balanceOf(address(this)) - initialBalance0;
        uint256 out1 = token1.balanceOf(address(this)) - initialBalance1;

        // no fees taken
        assertEq(outNormal0, out0);
        assertEq(outNormal1, out1);
    }

    function testVariousFactory() public {
        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
                | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
                | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG | Hooks.BEFORE_DONATE_FLAG | Hooks.AFTER_DONATE_FLAG
        );
        (address hookAddress, bytes32 salt) = HookMiner.find(
            address(factory),
            flags,
            type(MiddlewareRemove).creationCode,
            abi.encode(address(manager), address(hookscounter))
        );
        testOn(address(hookscounter), salt);

        flags = uint160(
            Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
                | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG
        );
        HooksRevert hooksRevert = HooksRevert(address(flags));
        vm.etch(address(hooksRevert), address(new HooksRevert(manager)).code);
        (hookAddress, salt) = HookMiner.find(
            address(factory),
            flags,
            type(MiddlewareRemove).creationCode,
            abi.encode(address(manager), address(hooksRevert))
        );
        testOn(address(hooksRevert), salt);

        HooksOutOfGas hooksOutOfGas = HooksOutOfGas(address(flags));
        vm.etch(address(hooksOutOfGas), address(new HooksOutOfGas(manager)).code);
        (hookAddress, salt) = HookMiner.find(
            address(factory),
            flags,
            type(MiddlewareRemove).creationCode,
            abi.encode(address(manager), address(hooksOutOfGas))
        );
        testOn(address(hooksOutOfGas), salt);
    }

    // creates a middleware on an implementation
    function testOn(address implementation, bytes32 salt) internal {
        address hookAddress = factory.createMiddleware(implementation, salt);

        (key,) = initPoolAndAddLiquidity(currency0, currency1, IHooks(hookAddress), 3000, SQRT_PRICE_1_1, ZERO_BYTES);

        // does not revert
        modifyLiquidityRouter.modifyLiquidity(key, REMOVE_LIQUIDITY_PARAMS, ZERO_BYTES);
        assertEq(factory.getImplementation(hookAddress), implementation);
    }

    function testRevertOnDeltaFlags() public {
        uint160 flags = uint160(Hooks.AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA_FLAG);
        address removeReturnDeltas = address(1 << 100 | flags);
        (address hookAddress, bytes32 salt) = HookMiner.find(
            address(factory),
            flags,
            type(MiddlewareRemove).creationCode,
            abi.encode(address(manager), address(removeReturnDeltas))
        );
        vm.expectRevert(abi.encodePacked(bytes16(MiddlewareRemove.HookPermissionForbidden.selector), hookAddress));
        factory.createMiddleware(address(removeReturnDeltas), salt);
    }

    // from BaseMiddlewareFactory.t.sol
    function testRevertOnSameDeployment() public {
        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
                | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
                | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG | Hooks.BEFORE_DONATE_FLAG | Hooks.AFTER_DONATE_FLAG
        );
        (, bytes32 salt) = HookMiner.find(
            address(factory),
            flags,
            type(MiddlewareRemove).creationCode,
            abi.encode(address(manager), address(hookscounter))
        );
        factory.createMiddleware(address(hookscounter), salt);
        // second deployment should revert
        vm.expectRevert(ZERO_BYTES);
        factory.createMiddleware(address(hookscounter), salt);
    }

    function testRevertOnIncorrectFlags() public {
        HooksCounter counter2 = HooksCounter(address(COUNTER_FLAGS));
        vm.etch(address(hookscounter), address(new HooksCounter(manager)).code);
        uint160 incorrectFlags = uint160(Hooks.BEFORE_INITIALIZE_FLAG);

        (address hookAddress, bytes32 salt) = HookMiner.find(
            address(factory),
            incorrectFlags,
            type(MiddlewareRemove).creationCode,
            abi.encode(address(manager), address(counter2))
        );
        address implementation = address(counter2);
        vm.expectRevert(BaseMiddleware.FlagsMismatch.selector);
        factory.createMiddleware(implementation, salt);
    }

    function testRevertOnIncorrectFlagsMined() public {
        HooksCounter counter2 = HooksCounter(address(COUNTER_FLAGS));
        vm.etch(address(hookscounter), address(new HooksCounter(manager)).code);
        address implementation = address(counter2);
        vm.expectRevert(BaseMiddleware.FlagsMismatch.selector);
        factory.createMiddleware(implementation, bytes32("who needs to mine a salt?"));
    }

    function testRevertOnIncorrectCaller() public {
        vm.expectRevert(SafeCallback.NotManager.selector);
        hookscounter.afterDonate(address(this), key, 0, 0, ZERO_BYTES);
    }

    function testCounters() public {
        (PoolKey memory key, PoolId id) =
            initPoolAndAddLiquidity(currency0, currency1, IHooks(middleware), 3000, SQRT_PRICE_1_1, ZERO_BYTES);

        HooksCounter counterProxy = HooksCounter(middleware);
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

        // hookscounter does not store data itself
        assertEq(hookscounter.lastHookData(), bytes(""));
        assertEq(hookscounter.beforeSwapCount(id), 0);
        assertEq(hookscounter.afterSwapCount(id), 0);

        modifyLiquidityRouter.modifyLiquidity(key, REMOVE_LIQUIDITY_PARAMS, ZERO_BYTES);
        assertEq(counterProxy.beforeRemoveLiquidityCount(id), 1);
        assertEq(counterProxy.afterRemoveLiquidityCount(id), 1);
    }
}
