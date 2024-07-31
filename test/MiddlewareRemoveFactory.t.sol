// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {HooksCounter} from "./middleware/HooksCounter.sol";
import {MiddlewareRemoveNoDeltas} from "../contracts/middleware/MiddlewareRemoveNoDeltas.sol";
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
import {MiddlewareMiner} from "./utils/MiddlewareMiner.sol";
import {SafeCallback} from "./../contracts/base/SafeCallback.sol";
import {FeeOnRemove} from "./middleware/FeeOnRemove.sol";
import {FrontrunRemove} from "./middleware/FrontrunRemove.sol";
import {BaseMiddleware} from "./../contracts/middleware/BaseMiddleware.sol";
import {RemoveGriefs} from "./middleware/RemoveGriefs.sol";
import {RemoveReturnsMaxDeltas} from "./middleware/RemoveReturnsMaxDeltas.sol";
import {BaseRemove} from "./../contracts/middleware/BaseRemove.sol";

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

        (address hookAddress, bytes32 salt) =
            MiddlewareMiner.find(address(factory), COUNTER_FLAGS, address(manager), address(hookscounter), 0);
        middleware = factory.createMiddleware(address(hookscounter), 0, salt);
        assertEq(hookAddress, middleware);
    }

    function testFrontrunRemove() public {
        uint160 flags = uint160(Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG);
        FrontrunRemove frontrunRemove = FrontrunRemove(address(flags));
        vm.etch(address(frontrunRemove), address(new FrontrunRemove(manager)).code);
        (, bytes32 salt) = MiddlewareMiner.find(address(factory), flags, address(manager), address(frontrunRemove), 0);
        middleware = factory.createMiddleware(address(frontrunRemove), 0, salt);
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
        // assertEq(outNormal0, out0);
        // assertEq(outNormal1, out1);

        // was frontrun
        assertTrue(out0 > outNormal0);
        assertTrue(out1 < outNormal1);
    }

    function testRevertOnNotSettled() public {
        uint160 flags = uint160(Hooks.AFTER_REMOVE_LIQUIDITY_FLAG);
        FeeOnRemove feeOnRemove = FeeOnRemove(address(flags));
        vm.etch(address(feeOnRemove), address(new FeeOnRemove(manager)).code);
        (key,) = initPoolAndAddLiquidity(currency0, currency1, IHooks(feeOnRemove), 3000, SQRT_PRICE_1_1, ZERO_BYTES);
        vm.expectRevert(IPoolManager.CurrencyNotSettled.selector);
        modifyLiquidityRouter.modifyLiquidity(key, REMOVE_LIQUIDITY_PARAMS, ZERO_BYTES);
    }

    function testFeesOnRemove() public {
        uint160 flags = uint160(Hooks.AFTER_REMOVE_LIQUIDITY_FLAG);
        FeeOnRemove feeOnRemove = FeeOnRemove(address(flags));
        vm.etch(address(feeOnRemove), address(new FeeOnRemove(manager)).code);

        (key,) = initPoolAndAddLiquidity(currency0, currency1, IHooks(feeOnRemove), 3000, SQRT_PRICE_1_1, ZERO_BYTES);
        vm.expectRevert(IPoolManager.CurrencyNotSettled.selector);
        modifyLiquidityRouter.modifyLiquidity(key, REMOVE_LIQUIDITY_PARAMS, ZERO_BYTES);
    }

    function testFeeOnVariousMaxFees() public {
        (uint256 outNormal0, uint256 outNormal1) = getNormal();
        (uint256 outWithFees0, uint256 outWithFees1) = getWithFees();
        uint256 out0;
        uint256 out1;
        (out0, out1) = testFeeOnRemove(0);
        assertEq(out0, outNormal0);
        assertEq(out1, outNormal1);
        (out0, out1) = testFeeOnRemove(100);
        assertEq(out0, outNormal0);
        assertEq(out1, outNormal1);
        (out0, out1) = testFeeOnRemove(542);
        assertEq(out0, outNormal0);
        assertEq(out1, outNormal1);
        // once we allow 543, the hook starts to charge fees
        (out0, out1) = testFeeOnRemove(543);
        assertEq(out0, outWithFees0);
        assertEq(out1, outWithFees1);
    }

    function getNormal() internal returns (uint256 outNormal0, uint256 outNormal1) {
        IHooks noHooks = IHooks(address(0));
        (key,) = initPoolAndAddLiquidity(currency0, currency1, noHooks, 3000, SQRT_PRICE_1_1, ZERO_BYTES);
        uint256 initialBalance0 = token0.balanceOf(address(this));
        uint256 initialBalance1 = token1.balanceOf(address(this));
        modifyLiquidityRouter.modifyLiquidity(key, REMOVE_LIQUIDITY_PARAMS, ZERO_BYTES);
        outNormal0 = token0.balanceOf(address(this)) - initialBalance0;
        outNormal1 = token1.balanceOf(address(this)) - initialBalance1;
    }

    function getWithFees() internal returns (uint256 outWithFees0, uint256 outWithFees1) {
        uint160 flags = uint160(Hooks.AFTER_REMOVE_LIQUIDITY_FLAG | Hooks.AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA_FLAG);
        FeeOnRemove feeOnRemove = FeeOnRemove(address(flags));
        vm.etch(address(feeOnRemove), address(new FeeOnRemove(manager)).code);
        (key,) = initPoolAndAddLiquidity(currency0, currency1, feeOnRemove, 3000, SQRT_PRICE_1_1, ZERO_BYTES);
        uint256 initialBalance0 = token0.balanceOf(address(this));
        uint256 initialBalance1 = token1.balanceOf(address(this));
        modifyLiquidityRouter.modifyLiquidity(key, REMOVE_LIQUIDITY_PARAMS, ZERO_BYTES);
        outWithFees0 = token0.balanceOf(address(this)) - initialBalance0;
        outWithFees1 = token1.balanceOf(address(this)) - initialBalance1;
    }

    function testFeeOnRemove(uint256 maxFeeBips) internal returns (uint256 out0, uint256 out1) {
        uint160 flags;
        if (maxFeeBips == 0) {
            flags = uint160(Hooks.AFTER_REMOVE_LIQUIDITY_FLAG);
        } else {
            flags = uint160(Hooks.AFTER_REMOVE_LIQUIDITY_FLAG | Hooks.AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA_FLAG);
        }
        FeeOnRemove feeOnRemove = FeeOnRemove(address(flags));
        vm.etch(address(feeOnRemove), address(new FeeOnRemove(manager)).code);
        (, bytes32 salt) =
            MiddlewareMiner.find(address(factory), flags, address(manager), address(feeOnRemove), maxFeeBips);
        middleware = factory.createMiddleware(address(feeOnRemove), maxFeeBips, salt);

        (key,) = initPoolAndAddLiquidity(currency0, currency1, IHooks(middleware), 3000, SQRT_PRICE_1_1, ZERO_BYTES);
        uint256 initialBalance0 = token0.balanceOf(address(this));
        uint256 initialBalance1 = token1.balanceOf(address(this));
        modifyLiquidityRouter.modifyLiquidity(key, REMOVE_LIQUIDITY_PARAMS, ZERO_BYTES);
        out0 = token0.balanceOf(address(this)) - initialBalance0;
        out1 = token1.balanceOf(address(this)) - initialBalance1;
    }

    function testVariousFactory() public {
        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
                | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
                | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG | Hooks.BEFORE_DONATE_FLAG | Hooks.AFTER_DONATE_FLAG
        );
        testOn(address(hookscounter), flags);

        flags = uint160(
            Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
                | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG
        );
        HooksRevert hooksRevert = HooksRevert(address(flags));
        vm.etch(address(hooksRevert), address(new HooksRevert(manager)).code);
        testOn(address(hooksRevert), flags);

        HooksOutOfGas hooksOutOfGas = HooksOutOfGas(address(flags));
        vm.etch(address(hooksOutOfGas), address(new HooksOutOfGas(manager)).code);
        testOn(address(hooksOutOfGas), flags);
    }

    function testGriefs() public {
        uint160 flags = uint160(Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG);
        RemoveGriefs removeGriefs = RemoveGriefs(address(flags));
        vm.etch(address(removeGriefs), address(new RemoveGriefs(manager)).code);
        testOn(address(removeGriefs), flags);

        flags = uint160(Hooks.AFTER_REMOVE_LIQUIDITY_FLAG);
        uint160 flagsWithDeltas = flags | Hooks.AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA_FLAG;
        (address hookAddress,) =
            MiddlewareMiner.find(address(factory), flagsWithDeltas, address(manager), address(flagsWithDeltas), 100);
        currency0.transfer(address(hookAddress), currency0.balanceOf(address(this)) / 2);
        currency1.transfer(address(hookAddress), currency1.balanceOf(address(this)) / 2);
        RemoveReturnsMaxDeltas removeReturnsMaxDeltas = RemoveReturnsMaxDeltas(address(flags));
        vm.etch(address(removeReturnsMaxDeltas), address(new RemoveReturnsMaxDeltas(manager)).code);
        testOn(address(removeReturnsMaxDeltas), flags);
    }

    // creates a middleware on an implementation
    function testOn(address implementation, uint160 flags) internal {
        uint256 maxFeeBips = 0;
        (, bytes32 salt) = MiddlewareMiner.find(address(factory), flags, address(manager), implementation, maxFeeBips);
        address hookAddress = factory.createMiddleware(implementation, maxFeeBips, salt);
        (key,) = initPoolAndAddLiquidity(currency0, currency1, IHooks(hookAddress), 3000, SQRT_PRICE_1_1, ZERO_BYTES);
        // does not revert
        uint256 gasLeft = gasleft();
        modifyLiquidityRouter.modifyLiquidity(key, REMOVE_LIQUIDITY_PARAMS, ZERO_BYTES);
        console.log("A", gasLeft - gasleft());
        assertEq(factory.getImplementation(hookAddress), implementation);

        flags = flags | Hooks.AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA_FLAG;
        address implementationWithReturnsDelta = address(flags);
        vm.etch(implementationWithReturnsDelta, implementation.code);
        maxFeeBips = 100;
        (, salt) =
            MiddlewareMiner.find(address(factory), flags, address(manager), implementationWithReturnsDelta, maxFeeBips);
        hookAddress = factory.createMiddleware(implementationWithReturnsDelta, maxFeeBips, salt);
        (key,) = initPoolAndAddLiquidity(currency0, currency1, IHooks(hookAddress), 3000, SQRT_PRICE_1_1, ZERO_BYTES);
        // does not revert
        gasLeft = gasleft();
        modifyLiquidityRouter.modifyLiquidity(key, REMOVE_LIQUIDITY_PARAMS, ZERO_BYTES);
        console.log("B", gasLeft - gasleft());
        assertEq(factory.getImplementation(hookAddress), implementationWithReturnsDelta);
    }

    function testRevertOnDeltaFlags() public {
        uint160 flags = uint160(Hooks.AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA_FLAG);
        address removeReturnDeltas = address(1 << 100 | flags);
        (address hookAddress, bytes32 salt) =
            MiddlewareMiner.find(address(factory), flags, address(manager), address(removeReturnDeltas), 0);
        vm.expectRevert(abi.encodePacked(bytes16(BaseRemove.HookPermissionForbidden.selector), hookAddress));
        factory.createMiddleware(address(removeReturnDeltas), 0, salt);
    }

    // from BaseMiddlewareFactory.t.sol
    function testRevertOnSameDeployment() public {
        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
                | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
                | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG | Hooks.BEFORE_DONATE_FLAG | Hooks.AFTER_DONATE_FLAG
        );
        (, bytes32 salt) = MiddlewareMiner.find(address(factory), flags, address(manager), address(hookscounter), 0);

        factory.createMiddleware(address(hookscounter), 0, salt);
        // second deployment should revert
        vm.expectRevert(ZERO_BYTES);
        factory.createMiddleware(address(hookscounter), 0, salt);
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

    function testDataChaining() public {
        (PoolKey memory key,) =
            initPoolAndAddLiquidity(currency0, currency1, IHooks(middleware), 3000, SQRT_PRICE_1_1, ZERO_BYTES);
        HooksCounter counterProxy = HooksCounter(middleware);
        modifyLiquidityRouter.modifyLiquidity(
            key, REMOVE_LIQUIDITY_PARAMS, hex"23b70c8dec38c3dec67a5596870027b04c4058cb3ac57b4e589bf628ac6669e7FFFF"
        );
        assertEq(counterProxy.lastHookData(), hex"FFFF");

        hookscounter = HooksCounter(address(COUNTER_FLAGS | Hooks.AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA_FLAG));
        vm.etch(address(hookscounter), address(new HooksCounter(manager)).code);
        (, bytes32 salt) = MiddlewareMiner.find(
            address(factory),
            COUNTER_FLAGS | Hooks.AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA_FLAG,
            address(manager),
            address(hookscounter),
            777
        );
        middleware = factory.createMiddleware(address(hookscounter), 777, salt);
        (key,) = initPoolAndAddLiquidity(currency0, currency1, IHooks(middleware), 3000, SQRT_PRICE_1_1, ZERO_BYTES);
        counterProxy = HooksCounter(middleware);
        modifyLiquidityRouter.modifyLiquidity(
            key, REMOVE_LIQUIDITY_PARAMS, hex"23b70c8dec38c3dec67a5596870027b04c4058cb3ac57b4e589bf628ac6669e7AAAA"
        );
        assertEq(counterProxy.lastHookData(), hex"AAAA");
    }
}
