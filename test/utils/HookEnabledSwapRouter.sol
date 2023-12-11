// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {CurrencyLibrary, Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IERC20Minimal} from "@uniswap/v4-core/src/interfaces/external/IERC20Minimal.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolTestBase} from "@uniswap/v4-core/src/test/PoolTestBase.sol";
import {Test} from "forge-std/Test.sol";

contract HookEnabledSwapRouter is PoolTestBase {
    using CurrencyLibrary for Currency;

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
        bool withdrawTokens;
        bool settleUsingTransfer;
    }

    function swap(
        PoolKey memory key,
        IPoolManager.SwapParams memory params,
        TestSettings memory testSettings,
        bytes memory hookData
    ) external payable returns (BalanceDelta delta) {
        delta = abi.decode(
            manager.lock(address(this), abi.encode(CallbackData(msg.sender, testSettings, key, params, hookData))),
            (BalanceDelta)
        );

        uint256 ethBalance = address(this).balance;
        if (ethBalance > 0) CurrencyLibrary.NATIVE.transfer(msg.sender, ethBalance);
    }

    function lockAcquired(address, /*sender*/ bytes calldata rawData) external returns (bytes memory) {
        require(msg.sender == address(manager));

        CallbackData memory data = abi.decode(rawData, (CallbackData));

        BalanceDelta delta = manager.swap(data.key, data.params, data.hookData);

        // Make sure youve added liquidity to the test pool!
        if (BalanceDelta.unwrap(delta) == 0) revert NoSwapOccurred();

        if (data.params.zeroForOne) {
            _settle(data.key.currency0, data.sender, delta.amount0(), data.testSettings.settleUsingTransfer);
            if (delta.amount1() < 0) {
                _take(data.key.currency1, data.sender, delta.amount1(), data.testSettings.withdrawTokens);
            }
        } else {
            _settle(data.key.currency1, data.sender, delta.amount1(), data.testSettings.settleUsingTransfer);
            if (delta.amount0() < 0) {
                _take(data.key.currency0, data.sender, delta.amount0(), data.testSettings.withdrawTokens);
            }
        }

        return abi.encode(delta);
    }
}
