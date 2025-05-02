// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolTestBase} from "@uniswap/v4-core/src/test/PoolTestBase.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {DeltaResolver} from "../../src/base/DeltaResolver.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import {ImmutableState} from "../../src/base/ImmutableState.sol";

contract TestRouter is PoolTestBase, DeltaResolver {
    using SafeCast for *;
    using TransientStateLibrary for IPoolManager;

    constructor(IPoolManager _manager) PoolTestBase(_manager) ImmutableState(_manager) {}

    error NoSwapOccurred();

    struct CallbackData {
        address sender;
        PoolKey key;
        SwapParams params;
        bytes hookData;
    }

    function swap(PoolKey memory key, SwapParams memory params, bytes memory hookData)
        external
        payable
        returns (BalanceDelta delta)
    {
        delta = abi.decode(manager.unlock(abi.encode(CallbackData(msg.sender, key, params, hookData))), (BalanceDelta));

        uint256 ethBalance = address(this).balance;
        if (ethBalance > 0) CurrencyLibrary.ADDRESS_ZERO.transfer(msg.sender, ethBalance);
    }

    function unlockCallback(bytes calldata rawData) external returns (bytes memory) {
        require(msg.sender == address(manager));

        CallbackData memory data = abi.decode(rawData, (CallbackData));

        BalanceDelta delta;
        (Currency inputCurrency, Currency outputCurrency) =
            data.params.zeroForOne ? (data.key.currency0, data.key.currency1) : (data.key.currency1, data.key.currency0);

        if (data.params.amountSpecified < 0) {
            // exact input
            _settle(inputCurrency, data.sender, uint256(-data.params.amountSpecified));
            uint256 amountIn = _getFullCredit(inputCurrency);
            delta = manager.swap(
                data.key,
                SwapParams(data.params.zeroForOne, -int256(amountIn), data.params.sqrtPriceLimitX96),
                data.hookData
            );
            _take(outputCurrency, data.sender, _getFullCredit(outputCurrency));
        } else {
            // exact output
            delta = manager.swap(
                data.key,
                SwapParams(data.params.zeroForOne, int256(data.params.amountSpecified), data.params.sqrtPriceLimitX96),
                data.hookData
            );

            _settle(inputCurrency, data.sender, _getFullDebt(inputCurrency));
            _take(outputCurrency, data.sender, _getFullCredit(outputCurrency));
        }

        return abi.encode(delta);
    }

    function _pay(Currency currency, address payer, uint256 amount) internal override {
        if (payer != address(this)) {
            IERC20(Currency.unwrap(currency)).transferFrom(payer, address(manager), amount);
        } else {
            IERC20(Currency.unwrap(currency)).transfer(address(manager), amount);
        }
    }
}
