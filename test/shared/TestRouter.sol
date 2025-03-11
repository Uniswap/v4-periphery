// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {console2} from "forge-std/console2.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
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
        IPoolManager.SwapParams params;
        bytes hookData;
    }

    function swap(PoolKey memory key, IPoolManager.SwapParams memory params, bytes memory hookData)
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
        (uint256 aliceBalancePreInput, uint256 poolBalancePreInput,) =
            _fetchBalances(inputCurrency, data.sender, address(this));
        (uint256 aliceBalancePreOutput, uint256 poolBalancePreOutput,) =
            _fetchBalances(outputCurrency, data.sender, address(this));

        if (data.params.amountSpecified < 0) {
            // exact input
            _settle(inputCurrency, data.sender, uint256(-data.params.amountSpecified));
            uint256 amountIn = _getFullCredit(inputCurrency);
            delta = manager.swap(
                data.key,
                IPoolManager.SwapParams(data.params.zeroForOne, -int256(amountIn), data.params.sqrtPriceLimitX96),
                data.hookData
            );
            _take(outputCurrency, data.sender, _getFullCredit(outputCurrency));
        } else {
            // exact output
            delta = manager.swap(
                data.key,
                IPoolManager.SwapParams(
                    data.params.zeroForOne, int256(data.params.amountSpecified), data.params.sqrtPriceLimitX96
                ),
                data.hookData
            );

            // console2.log("full debt pre", _getFullDebt(inputCurrency));
            _settle(inputCurrency, data.sender, _getFullDebt(inputCurrency));
            // console2.log("full credit pre", _getFullCredit(outputCurrency));
            _take(outputCurrency, data.sender, _getFullCredit(outputCurrency));
            // console2.log("full debt post", _getFullDebt(inputCurrency));
            // console2.log("full credit post", _getFullCredit(outputCurrency));
            // int256 _deltaInput = poolManager.currencyDelta(address(this), inputCurrency);
            // int256 _deltaOutput = poolManager.currencyDelta(address(this), outputCurrency);
            // console2.log("delta input", _deltaInput);
            // console2.log("delta output", _deltaOutput);
            // int256 _aliceDeltaInput = poolManager.currencyDelta(address(data.sender), inputCurrency);
            // int256 _aliceDeltaOutput = poolManager.currencyDelta(address(data.sender), outputCurrency);
            // console2.log("alice delta input", _aliceDeltaInput);
            // console2.log("alice delta output", _aliceDeltaOutput);
            int256 _hookDeltaInput = poolManager.currencyDelta(address(data.key.hooks), inputCurrency);
            int256 _hookDeltaOutput = poolManager.currencyDelta(address(data.key.hooks), outputCurrency);
            console2.log("hook delta input", _hookDeltaInput);
            console2.log("hook delta output", _hookDeltaOutput);
            console2.log("alice balance diff input", aliceBalancePreInput - inputCurrency.balanceOf(data.sender));
            console2.log("alice balance diff output", outputCurrency.balanceOf(data.sender) - aliceBalancePreOutput);
            console2.log("pool balance diff input", poolBalancePreInput - inputCurrency.balanceOf(address(manager)));
            console2.log("pool balance diff output", poolBalancePreOutput - outputCurrency.balanceOf(address(manager)));
            console2.log("hook balance input", inputCurrency.balanceOf(address(data.key.hooks)));
            console2.log("hook balance output", outputCurrency.balanceOf(address(data.key.hooks)));
            console2.log("NonzeroDeltas", manager.getNonzeroDeltaCount());
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
