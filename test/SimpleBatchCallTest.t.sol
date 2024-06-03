// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {SimpleBatchCall} from "../contracts/SimpleBatchCall.sol";
import {ICallsWithLock} from "../contracts/interfaces/ICallsWithLock.sol";

import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Pool} from "@uniswap/v4-core/src/libraries/Pool.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Test} from "forge-std/Test.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";

/// @title SimpleBatchCall
/// @notice Implements a naive settle function to perform any arbitrary batch call under one lock to modifyPosition, donate, intitialize, or swap.
contract SimpleBatchCallTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    SimpleBatchCall batchCall;

    function setUp() public {
        Deployers.deployFreshManagerAndRouters();
        Deployers.deployMintAndApprove2Currencies();
        key =
            PoolKey({currency0: currency0, currency1: currency1, fee: 3000, tickSpacing: 60, hooks: IHooks(address(0))});

        batchCall = new SimpleBatchCall(manager);
        ERC20(Currency.unwrap(currency0)).approve(address(batchCall), 2 ** 255);
        ERC20(Currency.unwrap(currency1)).approve(address(batchCall), 2 ** 255);
    }

    function test_initialize() public {
        bytes[] memory calls = new bytes[](1);
        calls[0] = abi.encodeWithSelector(ICallsWithLock.initializeWithLock.selector, key, SQRT_PRICE_1_1, ZERO_BYTES);
        bytes memory settleData =
            abi.encode(SimpleBatchCall.SettleConfig({takeClaims: false, settleUsingBurn: false}));
        batchCall.execute(abi.encode(calls), ZERO_BYTES);

        (uint160 sqrtPriceX96,,,) = manager.getSlot0(key.toId());
        assertEq(sqrtPriceX96, SQRT_PRICE_1_1);
    }

    function test_initialize_modifyPosition() public {
        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeWithSelector(ICallsWithLock.initializeWithLock.selector, key, SQRT_PRICE_1_1, ZERO_BYTES);
        calls[1] = abi.encodeWithSelector(
            ICallsWithLock.modifyPositionWithLock.selector,
            key,
            IPoolManager.ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: 10 * 10 ** 18, salt: 0}),
            ZERO_BYTES
        );
        Currency[] memory currenciesTouched = new Currency[](2);
        currenciesTouched[0] = currency0;
        currenciesTouched[1] = currency1;
        bytes memory settleData = abi.encode(
            currenciesTouched, SimpleBatchCall.SettleConfig({takeClaims: false, settleUsingBurn: false})
        );
        uint256 balance0 = ERC20(Currency.unwrap(currency0)).balanceOf(address(manager));
        uint256 balance1 = ERC20(Currency.unwrap(currency1)).balanceOf(address(manager));
        batchCall.execute(abi.encode(calls), settleData);
        uint256 balance0After = ERC20(Currency.unwrap(currency0)).balanceOf(address(manager));
        uint256 balance1After = ERC20(Currency.unwrap(currency1)).balanceOf(address(manager));

        (uint160 sqrtPriceX96,,,) = manager.getSlot0(key.toId());

        assertGt(balance0After, balance0);
        assertGt(balance1After, balance1);
        assertEq(sqrtPriceX96, SQRT_PRICE_1_1);
    }
}
