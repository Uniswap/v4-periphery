// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {CurrencyLibrary, Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IERC20Minimal} from "@uniswap/v4-core/src/interfaces/external/IERC20Minimal.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolTestBase} from "@uniswap/v4-core/src/test/PoolTestBase.sol";
import {Test} from "forge-std/Test.sol";
import {CurrencySettler} from "@uniswap/v4-core/test/utils/CurrencySettler.sol";

contract HookEnabledSwapRouter is PoolTestBase {
    using CurrencyLibrary for Currency;
    using CurrencySettler for Currency;

    error NoSwapOccurred();

    constructor(IPoolManager _manager) PoolTestBase(_manager) {}

    struct CallbackData {
        address sender;
        TestSettings testSettings;
        PoolKey key;
        IPoolManager.SwapParams params;
        bytes hookData;
    }

    struct TestSettings {
        bool takeClaims;
        bool settleUsingBurn;
    }

    function swap(
        PoolKey memory key,
        IPoolManager.SwapParams memory params,
        TestSettings memory testSettings,
        bytes memory hookData
    ) external payable returns (BalanceDelta delta) {
        delta = abi.decode(
            manager.unlock(abi.encode(CallbackData(msg.sender, testSettings, key, params, hookData))), (BalanceDelta)
        );

        uint256 ethBalance = address(this).balance;
        if (ethBalance > 0) CurrencyLibrary.NATIVE.transfer(msg.sender, ethBalance);
    }

    function unlockCallback(bytes calldata rawData) external returns (bytes memory) {
        require(msg.sender == address(manager));

        CallbackData memory data = abi.decode(rawData, (CallbackData));

        BalanceDelta delta = manager.swap(data.key, data.params, data.hookData);

        // Make sure youve added liquidity to the test pool!
        if (BalanceDelta.unwrap(delta) == 0) revert NoSwapOccurred();

        if (data.params.zeroForOne) {
            data.key.currency0.settle(
                manager, data.sender, uint256(int256(-delta.amount0())), data.testSettings.settleUsingBurn
            );
            if (delta.amount1() > 0) {
                data.key.currency1.take(
                    manager, data.sender, uint256(int256(delta.amount1())), data.testSettings.takeClaims
                );
            }
        } else {
            data.key.currency1.settle(
                manager, data.sender, uint256(int256(-delta.amount1())), data.testSettings.settleUsingBurn
            );
            if (delta.amount0() > 0) {
                data.key.currency0.take(
                    manager, data.sender, uint256(int256(delta.amount0())), data.testSettings.takeClaims
                );
            }
        }

        return abi.encode(delta);
    }
}
