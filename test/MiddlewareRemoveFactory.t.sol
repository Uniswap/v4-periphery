// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {Test} from "forge-std/Test.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {MiddlewareRemove} from "../contracts/middleware/MiddlewareRemove.sol";
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
import {MiddlewareRemoveFactory} from "./../contracts/middleware/MiddlewareRemoveFactory.sol";
import {HookMiner} from "./utils/HookMiner.sol";
import {HooksDoNothing} from "./middleware/HooksDoNothing.sol";

contract MiddlewareRemoveFactoryTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    uint160 constant SQRT_RATIO_10_1 = 250541448375047931186413801569;

    address constant TREASURY = address(0x1234567890123456789012345678901234567890);
    uint128 private constant TOTAL_BIPS = 10000;

    HookEnabledSwapRouter router;
    TestERC20 token0;
    TestERC20 token1;
    PoolId id;

    MiddlewareRemoveFactory factory;
    HooksDoNothing hooksDoNothing;

    function setUp() public {
        deployFreshManagerAndRouters();
        (currency0, currency1) = deployMintAndApprove2Currencies();

        router = new HookEnabledSwapRouter(manager);
        token0 = TestERC20(Currency.unwrap(currency0));
        token1 = TestERC20(Currency.unwrap(currency1));

        token0.approve(address(router), type(uint256).max);
        token1.approve(address(router), type(uint256).max);

        factory = new MiddlewareRemoveFactory(manager);
        hooksDoNothing = new HooksDoNothing(manager, address(factory));
    }

    function testRevertOnIncorrectFlags() public {
        uint160 flags = uint160(Hooks.BEFORE_INITIALIZE_FLAG);

        (address hookAddress, bytes32 salt) = HookMiner.find(
            address(factory),
            flags,
            type(MiddlewareRemove).creationCode,
            abi.encode(address(manager), address(hooksDoNothing))
        );
        address implementation = address(hooksDoNothing);
        vm.expectRevert(abi.encodePacked(bytes16(Hooks.HookAddressNotValid.selector), hookAddress));
        factory.createMiddleware(implementation, salt);
    }

    function testRevertOnIncorrectFlagsMined() public {
        address implementation = address(hooksDoNothing);
        vm.expectRevert(); // HookAddressNotValid
        factory.createMiddleware(implementation, bytes32("who needs to mine a salt?"));
    }

    function testVariousFactory() public {
        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
                | Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG
                | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_DONATE_FLAG | Hooks.AFTER_DONATE_FLAG
        );
        (address hookAddress, bytes32 salt) = HookMiner.find(
            address(factory),
            flags,
            type(MiddlewareRemove).creationCode,
            abi.encode(address(manager), address(hooksDoNothing))
        );
        _testOn(address(hooksDoNothing), salt);

        HooksRevert hooksRevert = new HooksRevert(manager, address(factory));
        flags = uint160(
            Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG
                | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_DONATE_FLAG | Hooks.AFTER_DONATE_FLAG
        );
        (hookAddress, salt) = HookMiner.find(
            address(factory),
            flags,
            type(MiddlewareRemove).creationCode,
            abi.encode(address(manager), address(hooksRevert))
        );
        _testOn(address(hooksRevert), salt);

        HooksOutOfGas hooksOutOfGas = new HooksOutOfGas(manager, address(factory));
        (hookAddress, salt) = HookMiner.find(
            address(factory),
            flags,
            type(MiddlewareRemove).creationCode,
            abi.encode(address(manager), address(hooksOutOfGas))
        );
        _testOn(address(hooksOutOfGas), salt);
    }

    // creates a middleware on an implementation
    function _testOn(address implementation, bytes32 salt) internal {
        address hookAddress = factory.createMiddleware(implementation, salt);
        MiddlewareRemove middlewareRemove = MiddlewareRemove(payable(hookAddress));

        (key, id) = initPoolAndAddLiquidity(
            currency0, currency1, IHooks(address(middlewareRemove)), 3000, SQRT_PRICE_1_1, ZERO_BYTES
        );

        // removeLiquidity does not fail
        removeLiquidity(currency0, currency1, IHooks(address(middlewareRemove)), 3000, SQRT_PRICE_1_1, ZERO_BYTES);
        assertEq(factory.getImplementation(hookAddress), implementation);
    }
}
