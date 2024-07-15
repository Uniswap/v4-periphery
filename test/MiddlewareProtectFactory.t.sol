// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {Test} from "forge-std/Test.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {HooksFrontrun} from "./middleware/HooksFrontrun.sol";
import {MiddlewareRemove} from "../contracts/middleware/MiddlewareRemove.sol";
import {MiddlewareProtect} from "../contracts/middleware/MiddlewareProtect.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {TestERC20} from "@uniswap/v4-core/src/test/TestERC20.sol";
import {CurrencyLibrary, Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {HookEnabledSwapRouter} from "./utils/HookEnabledSwapRouter.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {console} from "../../../lib/forge-std/src/console.sol";
import {HooksRevert} from "./middleware/HooksRevert.sol";
import {HooksOutOfGas} from "./middleware/HooksOutOfGas.sol";
import {MiddlewareProtectFactory} from "./../contracts/middleware/MiddlewareProtectFactory.sol";
import {HookMiner} from "./utils/HookMiner.sol";
import {HooksReturnDeltas} from "./middleware/HooksReturnDeltas.sol";
import {Counter} from "./middleware/Counter.sol";
import {SafeCallback} from "./../contracts/base/SafeCallback.sol";
import {FrontrunAdd} from "./middleware/FrontrunAdd.sol";
import {IQuoter} from "./../contracts/interfaces/IQuoter.sol";
import {Quoter} from "./../contracts/lens/Quoter.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";

contract MiddlewareProtectFactoryTest is Test, Deployers {
    HookEnabledSwapRouter router;
    TestERC20 token0;
    TestERC20 token1;

    MiddlewareProtectFactory factory;
    Counter counter;
    address middleware;
    HooksFrontrun hooksFrontrun;
    IQuoter quoter;

    function setUp() public {
        deployFreshManagerAndRouters();
        (currency0, currency1) = deployMintAndApprove2Currencies();

        quoter = new Quoter(address(manager));

        router = new HookEnabledSwapRouter(manager);
        token0 = TestERC20(Currency.unwrap(currency0));
        token1 = TestERC20(Currency.unwrap(currency1));

        factory = new MiddlewareProtectFactory(manager);
        counter = new Counter(manager);

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
            type(MiddlewareProtect).creationCode,
            abi.encode(address(manager), address(counter))
        );
        middleware = factory.createMiddleware(address(counter), salt);
        assertEq(hookAddress, middleware);

        flags = uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG);
        hooksFrontrun = HooksFrontrun(address(uint160(flags)));
        HooksFrontrun impl = new HooksFrontrun(manager);
        vm.etch(address(hooksFrontrun), address(impl).code);
    }

    function testRevertOnDeltas() public {
        HooksReturnDeltas hooksReturnDeltas = new HooksReturnDeltas(manager);
        uint160 flags = uint160(Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG);

        (address hookAddress, bytes32 salt) = HookMiner.find(
            address(factory),
            flags,
            type(MiddlewareProtect).creationCode,
            abi.encode(address(manager), address(hooksReturnDeltas))
        );
        address implementation = address(hooksReturnDeltas);
        vm.expectRevert(abi.encodePacked(bytes16(MiddlewareRemove.HookPermissionForbidden.selector), hookAddress));
        factory.createMiddleware(implementation, salt);
    }

    function testFrontrun() public {
        return;
        (PoolKey memory key,) =
            initPoolAndAddLiquidity(currency0, currency1, IHooks(address(0)), 100, SQRT_PRICE_1_1, ZERO_BYTES);
        BalanceDelta swapDelta = swap(key, true, 0.001 ether, ZERO_BYTES);

        (key,) = initPoolAndAddLiquidity(
            currency0, currency1, IHooks(address(hooksFrontrun)), 100, SQRT_PRICE_1_1, ZERO_BYTES
        );
        BalanceDelta swapDelta2 = swap(key, true, 0.001 ether, ZERO_BYTES);

        // while both swaps are in the same pool, the second swap is more expensive
        assertEq(swapDelta.amount1(), swapDelta2.amount1());
        assertTrue(abs(swapDelta.amount0()) < abs(swapDelta2.amount0()));
        assertTrue(manager.balanceOf(address(hooksFrontrun), CurrencyLibrary.toId(key.currency0)) > 0);
    }

    function testRevertOnFrontrun() public {
        uint160 flags = uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG);

        (address hookAddress, bytes32 salt) = HookMiner.find(
            address(factory),
            flags,
            type(MiddlewareProtect).creationCode,
            abi.encode(address(manager), address(hooksFrontrun))
        );
        address implementation = address(hooksFrontrun);
        address hookAddressCreated = factory.createMiddleware(implementation, salt);
        assertEq(hookAddressCreated, hookAddress);
        MiddlewareProtect middlewareProtect = MiddlewareProtect(payable(hookAddress));

        (key,) = initPoolAndAddLiquidity(
            currency0, currency1, IHooks(address(middlewareProtect)), 100, SQRT_PRICE_1_1, ZERO_BYTES
        );
        vm.expectRevert(MiddlewareProtect.HookModifiedOutput.selector);
        swap(key, true, 0.001 ether, ZERO_BYTES);
    }

    function testRevertOnFailedImplementationCall() public {
        HooksRevert hooksRevert = new HooksRevert(manager);
        uint160 flags = uint160(
            Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
                | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG
        );
        (address hookAddress, bytes32 salt) = HookMiner.find(
            address(factory),
            flags,
            type(MiddlewareRemove).creationCode,
            abi.encode(address(manager), address(hooksRevert))
        );

        HooksOutOfGas hooksOutOfGas = new HooksOutOfGas(manager);
        (hookAddress, salt) = HookMiner.find(
            address(factory),
            flags,
            type(MiddlewareRemove).creationCode,
            abi.encode(address(manager), address(hooksOutOfGas))
        );
    }

    function testFrontrunAdd() public {
        uint160 flags = uint160(Hooks.BEFORE_ADD_LIQUIDITY_FLAG);
        FrontrunAdd frontrunAdd = FrontrunAdd(address(flags));
        FrontrunAdd impl = new FrontrunAdd(manager);
        vm.etch(address(frontrunAdd), address(impl).code);
        (, bytes32 salt) = HookMiner.find(
            address(factory),
            flags,
            type(MiddlewareProtect).creationCode,
            abi.encode(address(manager), address(frontrunAdd))
        );
        middleware = factory.createMiddleware(address(frontrunAdd), salt);
        currency0.transfer(address(frontrunAdd), 1 ether);
        currency1.transfer(address(frontrunAdd), 1 ether);
        currency0.transfer(address(middleware), 1 ether);
        currency1.transfer(address(middleware), 1 ether);

        (PoolKey memory key,) =
            initPoolAndAddLiquidity(currency0, currency1, IHooks(frontrunAdd), 3000, SQRT_PRICE_1_1, ZERO_BYTES);
        uint256 initialBalance0 = token0.balanceOf(address(this));
        uint256 initialBalance1 = token1.balanceOf(address(this));
        modifyLiquidityRouter.modifyLiquidity(key, LIQUIDITY_PARAMS, ZERO_BYTES);
        uint256 inFrontrun0 = initialBalance0 - token0.balanceOf(address(this));
        uint256 inFrontrun1 = initialBalance1 - token1.balanceOf(address(this));

        IHooks noHooks = IHooks(address(0));
        (key,) = initPoolAndAddLiquidity(currency0, currency1, noHooks, 3000, SQRT_PRICE_1_1, ZERO_BYTES);
        initialBalance0 = token0.balanceOf(address(this));
        initialBalance1 = token1.balanceOf(address(this));
        modifyLiquidityRouter.modifyLiquidity(key, LIQUIDITY_PARAMS, ZERO_BYTES);
        uint256 inNormal0 = initialBalance0 - token0.balanceOf(address(this));
        uint256 inNormal1 = initialBalance1 - token1.balanceOf(address(this));

        // was frontrun
        assertTrue(inFrontrun0 > inNormal0);
        assertTrue(inFrontrun1 < inNormal1);

        initialBalance0 = token0.balanceOf(address(this));
        initialBalance1 = token1.balanceOf(address(this));
        (key,) = initPoolAndAddLiquidity(currency0, currency1, IHooks(middleware), 3000, SQRT_PRICE_1_1, ZERO_BYTES);
        vm.expectRevert(MiddlewareRemove.HookModifiedPrice.selector);
        modifyLiquidityRouter.modifyLiquidity(key, LIQUIDITY_PARAMS, ZERO_BYTES);
    }

    function testRevertOnDynamicFee() public {
        vm.expectRevert(MiddlewareProtect.ForbiddenDynamicFee.selector);
        initPool(
            currency0, currency1, IHooks(middleware), LPFeeLibrary.DYNAMIC_FEE_FLAG, SQRT_PRICE_1_1, ZERO_BYTES
        );
    }

    function testVariousSwaps() public {
        (PoolKey memory key, PoolId id) =
            initPoolAndAddLiquidity(currency0, currency1, IHooks(middleware), 3000, SQRT_PRICE_1_1, ZERO_BYTES);
        swap(key, true, 1 ether, ZERO_BYTES);
        swap(key, false, 1 ether, ZERO_BYTES);
        swap(key, true, -1 ether, ZERO_BYTES);
        swap(key, false, -1 ether, ZERO_BYTES);
    }

    function abs(int256 x) internal pure returns (uint256) {
        return x >= 0 ? uint256(x) : uint256(-x);
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
            type(MiddlewareProtect).creationCode,
            abi.encode(address(manager), address(counter))
        );
        factory.createMiddleware(address(counter), salt);
        // second deployment should revert
        vm.expectRevert(ZERO_BYTES);
        factory.createMiddleware(address(counter), salt);
    }

    function testRevertOnIncorrectFlags() public {
        Counter counter2 = new Counter(manager);
        uint160 flags = uint160(Hooks.BEFORE_INITIALIZE_FLAG);

        (address hookAddress, bytes32 salt) = HookMiner.find(
            address(factory),
            flags,
            type(MiddlewareProtect).creationCode,
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
