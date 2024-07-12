// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {Test} from "forge-std/Test.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {Counter} from "./middleware/Counter.sol";
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
import {RemoveReverts} from "./middleware/RemoveReverts.sol";
import {RemoveOutOfGas} from "./middleware/RemoveOutOfGas.sol";
import {MiddlewareRemoveFactory} from "./../contracts/middleware/MiddlewareRemoveFactory.sol";
import {HookMiner} from "./utils/HookMiner.sol";
import {SafeCallback} from "./../contracts/base/SafeCallback.sol";
import {FeeOnRemove} from "./middleware/FeeOnRemove.sol";
import {FrontrunRemove} from "./middleware/FrontrunRemove.sol";

contract MiddlewareRemoveFactoryTest is Test, Deployers {
    HookEnabledSwapRouter router;
    TestERC20 token0;
    TestERC20 token1;

    MiddlewareRemoveFactory factory;
    Counter counter;
    address middleware;

    function setUp() public {
        deployFreshManagerAndRouters();
        (currency0, currency1) = deployMintAndApprove2Currencies();

        router = new HookEnabledSwapRouter(manager);
        token0 = TestERC20(Currency.unwrap(currency0));
        token1 = TestERC20(Currency.unwrap(currency1));

        factory = new MiddlewareRemoveFactory(manager);
        counter = new Counter(manager);

        token0.approve(address(router), type(uint256).max);
        token1.approve(address(router), type(uint256).max);

        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
                | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
                | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG | Hooks.BEFORE_DONATE_FLAG | Hooks.AFTER_DONATE_FLAG
        );

        (address hookAddress, bytes32 salt) = HookMiner.find(
            address(factory), flags, type(MiddlewareRemove).creationCode, abi.encode(address(manager), address(counter))
        );
        middleware = factory.createMiddleware(address(counter), salt);
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

        initPoolAndAddLiquidity(currency0, currency1, IHooks(frontrunRemove), 3000, SQRT_PRICE_1_1, ZERO_BYTES);
        uint256 initialBalance0 = token0.balanceOf(address(this));
        uint256 initialBalance1 = token1.balanceOf(address(this));
        removeLiquidity(currency0, currency1, IHooks(frontrunRemove), 3000, SQRT_PRICE_1_1, ZERO_BYTES);
        uint256 outFrontrun0 = token0.balanceOf(address(this)) - initialBalance0;
        uint256 outFrontrun1 = token1.balanceOf(address(this)) - initialBalance1;

        IHooks noHooks = IHooks(address(0));
        initPoolAndAddLiquidity(currency0, currency1, noHooks, 3000, SQRT_PRICE_1_1, ZERO_BYTES);
        initialBalance0 = token0.balanceOf(address(this));
        initialBalance1 = token1.balanceOf(address(this));
        removeLiquidity(currency0, currency1, noHooks, 3000, SQRT_PRICE_1_1, ZERO_BYTES);
        uint256 outNormal0 = token0.balanceOf(address(this)) - initialBalance0;
        uint256 outNormal1 = token1.balanceOf(address(this)) - initialBalance1;

        // was frontrun
        assertTrue(outFrontrun0 > outNormal0);
        assertTrue(outFrontrun1 < outNormal1);

        initPoolAndAddLiquidity(currency0, currency1, IHooks(middleware), 3000, SQRT_PRICE_1_1, ZERO_BYTES);
        initialBalance0 = token0.balanceOf(address(this));
        initialBalance1 = token1.balanceOf(address(this));
        removeLiquidity(currency0, currency1, IHooks(middleware), 3000, SQRT_PRICE_1_1, ZERO_BYTES);
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

        initPoolAndAddLiquidity(currency0, currency1, IHooks(feeOnRemove), 3000, SQRT_PRICE_1_1, ZERO_BYTES);
        vm.expectRevert(IPoolManager.CurrencyNotSettled.selector);
        removeLiquidity(currency0, currency1, IHooks(feeOnRemove), 3000, SQRT_PRICE_1_1, ZERO_BYTES);

        IHooks noHooks = IHooks(address(0));
        initPoolAndAddLiquidity(currency0, currency1, noHooks, 3000, SQRT_PRICE_1_1, ZERO_BYTES);
        uint256 initialBalance0 = token0.balanceOf(address(this));
        uint256 initialBalance1 = token1.balanceOf(address(this));
        removeLiquidity(currency0, currency1, noHooks, 3000, SQRT_PRICE_1_1, ZERO_BYTES);
        uint256 outNormal0 = token0.balanceOf(address(this)) - initialBalance0;
        uint256 outNormal1 = token1.balanceOf(address(this)) - initialBalance1;

        initPoolAndAddLiquidity(currency0, currency1, IHooks(middleware), 3000, SQRT_PRICE_1_1, ZERO_BYTES);
        initialBalance0 = token0.balanceOf(address(this));
        initialBalance1 = token1.balanceOf(address(this));
        removeLiquidity(currency0, currency1, IHooks(middleware), 3000, SQRT_PRICE_1_1, ZERO_BYTES);
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
            address(factory), flags, type(MiddlewareRemove).creationCode, abi.encode(address(manager), address(counter))
        );
        testOn(address(counter), salt);

        RemoveReverts removeReverts = new RemoveReverts(manager);
        flags = uint160(Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG);
        (hookAddress, salt) = HookMiner.find(
            address(factory),
            flags,
            type(MiddlewareRemove).creationCode,
            abi.encode(address(manager), address(removeReverts))
        );
        testOn(address(removeReverts), salt);

        RemoveOutOfGas removeOutOfGas = new RemoveOutOfGas(manager);
        (hookAddress, salt) = HookMiner.find(
            address(factory),
            flags,
            type(MiddlewareRemove).creationCode,
            abi.encode(address(manager), address(removeOutOfGas))
        );
        testOn(address(removeOutOfGas), salt);
    }

    // creates a middleware on an implementation
    function testOn(address implementation, bytes32 salt) internal {
        address hookAddress = factory.createMiddleware(implementation, salt);

        initPoolAndAddLiquidity(currency0, currency1, IHooks(hookAddress), 3000, SQRT_PRICE_1_1, ZERO_BYTES);

        // does not revert
        removeLiquidity(currency0, currency1, IHooks(hookAddress), 3000, SQRT_PRICE_1_1, ZERO_BYTES);
        assertEq(factory.getImplementation(hookAddress), implementation);
    }

    function testRevertOnDeltaFlags() public {
        uint160 flags = uint160(Hooks.AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA_FLAG);
        (address hookAddress, bytes32 salt) = HookMiner.find(
            address(factory), flags, type(MiddlewareRemove).creationCode, abi.encode(address(manager), address(counter))
        );
        vm.expectRevert(abi.encodePacked(bytes16(MiddlewareRemove.HookPermissionForbidden.selector), hookAddress));
        factory.createMiddleware(address(counter), salt);
    }

    // from BaseMiddlewareFactory.t.sol
    function testRevertOnSameDeployment() public {
        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
                | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
                | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG | Hooks.BEFORE_DONATE_FLAG | Hooks.AFTER_DONATE_FLAG
        );
        (, bytes32 salt) = HookMiner.find(
            address(factory), flags, type(MiddlewareRemove).creationCode, abi.encode(address(manager), address(counter))
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
            address(factory),
            flags,
            type(MiddlewareRemove).creationCode,
            abi.encode(address(manager), address(counter2))
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
