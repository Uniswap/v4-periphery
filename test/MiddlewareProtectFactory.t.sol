// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {Test} from "forge-std/Test.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {FeeTakingLite} from "./middleware/FeeTakingLite.sol";
import {MiddlewareProtect} from "../contracts/middleware/MiddlewareProtect.sol";
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
import {MiddlewareProtectFactory} from "./../contracts/middleware/MiddlewareProtectFactory.sol";
import {HookMiner} from "./utils/HookMiner.sol";

contract MiddlewareProtectFactoryTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    uint160 constant SQRT_RATIO_10_1 = 250541448375047931186413801569;

    address constant TREASURY = address(0x1234567890123456789012345678901234567890);
    uint128 private constant TOTAL_BIPS = 10000;

    HookEnabledSwapRouter router;
    TestERC20 token0;
    TestERC20 token1;
    PoolId id;

    MiddlewareProtectFactory factory;

    function setUp() public {
        deployFreshManagerAndRouters();
        (currency0, currency1) = deployMintAndApprove2Currencies();

        router = new HookEnabledSwapRouter(manager);
        token0 = TestERC20(Currency.unwrap(currency0));
        token1 = TestERC20(Currency.unwrap(currency1));

        token0.approve(address(router), type(uint256).max);
        token1.approve(address(router), type(uint256).max);

        factory = new MiddlewareProtectFactory(manager);
    }

    function testVariousProtectFactory() public {
        FeeTakingLite feeTakingLite = new FeeTakingLite(manager);
        uint160 flags =
            uint160(Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG);
        (address hookAddress, bytes32 salt) = HookMiner.find(
            address(factory),
            flags,
            type(MiddlewareProtect).creationCode,
            abi.encode(address(manager), address(feeTakingLite))
        );
        testOn(address(feeTakingLite), salt);

        HooksRevert hooksRevert = new HooksRevert(manager);
        flags = uint160(Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG);
        (hookAddress, salt) = HookMiner.find(
            address(factory),
            flags,
            type(MiddlewareProtect).creationCode,
            abi.encode(address(manager), address(hooksRevert))
        );
        testOn(address(hooksRevert), salt);

        HooksOutOfGas hooksOutOfGas = new HooksOutOfGas(manager);
        flags = uint160(Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG);
        (hookAddress, salt) = HookMiner.find(
            address(factory),
            flags,
            type(MiddlewareProtect).creationCode,
            abi.encode(address(manager), address(hooksOutOfGas))
        );
        testOn(address(hooksOutOfGas), salt);
    }

    // creates a middleware on an implementation
    function testOn(address implementation, bytes32 salt) internal {
        address hookAddress = factory.createMiddleware(implementation, salt);
        MiddlewareProtect middlewareProtect = MiddlewareProtect(payable(hookAddress));

        (key, id) = initPoolAndAddLiquidity(
            currency0, currency1, IHooks(address(middlewareProtect)), 3000, SQRT_PRICE_1_1, ZERO_BYTES
        );

        removeLiquidity(currency0, currency1, IHooks(address(middlewareProtect)), 3000, SQRT_PRICE_1_1, ZERO_BYTES);

        assertEq(factory.getImplementation(hookAddress), implementation);
    }
}
