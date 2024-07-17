// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PathKey} from "./libraries/PathKey.sol";
import {IV4Router} from "./interfaces/IV4Router.sol";

/// @title UniswapV4Router
/// @notice Abstract contract that contains all internal logic needed for routing through Uniswap V4 pools
abstract contract V4Router is IV4Router {
    using CurrencyLibrary for Currency;
    using TransientStateLibrary for IPoolManager;

    IPoolManager immutable poolManager;

    constructor(IPoolManager _poolManager) {
        poolManager = _poolManager;
    }

    function _v4Swap(SwapType swapType, bytes memory params) internal {
        poolManager.unlock(abi.encode(swapType, msg.sender, params));
    }

    /// @inheritdoc IUnlockCallback
    function unlockCallback(bytes calldata encodedSwapInfo) external override returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();

        (SwapType swapType, address msgSender, bytes memory params) =
            abi.decode(encodedSwapInfo, (SwapType, address, bytes));

        Currency inputCurrency;
        Currency outputCurrency;

        if (swapType == SwapType.ExactInput) {
            IV4Router.ExactInputParams memory params = abi.decode(params, (IV4Router.ExactInputParams));
            inputCurrency = params.currencyIn;
            outputCurrency = params.path[params.path.length - 1].intermediateCurrency;

            _swapExactInput(params);
        } else if (swapType == SwapType.ExactInputSingle) {
            IV4Router.ExactInputSingleParams memory params = abi.decode(params, (IV4Router.ExactInputSingleParams));
            (inputCurrency, outputCurrency) = params.zeroForOne
                ? (params.poolKey.currency0, params.poolKey.currency1)
                : (params.poolKey.currency1, params.poolKey.currency0);

            _swapExactInputSingle(params);
        } else if (swapType == SwapType.ExactOutput) {
            IV4Router.ExactOutputParams memory params = abi.decode(params, (IV4Router.ExactOutputParams));
            inputCurrency = params.path[0].intermediateCurrency;
            outputCurrency = params.currencyOut;

            _swapExactOutput(params);
        } else if (swapType == SwapType.ExactOutputSingle) {
            IV4Router.ExactOutputSingleParams memory params = abi.decode(params, (IV4Router.ExactOutputSingleParams));
            (inputCurrency, outputCurrency) = params.zeroForOne
                ? (params.poolKey.currency0, params.poolKey.currency1)
                : (params.poolKey.currency1, params.poolKey.currency0);

            _swapExactOutputSingle(params);
        } else {
            revert InvalidSwapType();
        }

        // settle
        _payAndSettle(inputCurrency, msgSender);

        // take
        _take(outputCurrency, msgSender);

        return bytes("");
    }

    function _swapExactInputSingle(IV4Router.ExactInputSingleParams memory params) private {
        _swap(
            params.poolKey,
            params.zeroForOne,
            int256(-int128(params.amountIn)),
            params.sqrtPriceLimitX96,
            params.hookData
        );
    }

    function _swapExactInput(IV4Router.ExactInputParams memory params) private {
        unchecked {
            uint256 pathLength = params.path.length;
            uint128 amountOut;

            for (uint256 i = 0; i < pathLength; i++) {
                (PoolKey memory poolKey, bool zeroForOne) = _getPoolAndSwapDirection(params.path[i], params.currencyIn);
                amountOut =
                    uint128(_swap(poolKey, zeroForOne, int256(-int128(params.amountIn)), 0, params.path[i].hookData));

                params.amountIn = amountOut;
                params.currencyIn = params.path[i].intermediateCurrency;
            }

            if (amountOut < params.amountOutMinimum) revert TooLittleReceived();
        }
    }

    function _swapExactOutputSingle(IV4Router.ExactOutputSingleParams memory params) private {
        _swap(
            params.poolKey,
            params.zeroForOne,
            int256(int128(params.amountOut)),
            params.sqrtPriceLimitX96,
            params.hookData
        );
    }

    function _swapExactOutput(IV4Router.ExactOutputParams memory params) private {
        unchecked {
            uint256 pathLength = params.path.length;
            uint128 amountIn;

            for (uint256 i = pathLength; i > 0; i--) {
                (PoolKey memory poolKey, bool oneForZero) =
                    _getPoolAndSwapDirection(params.path[i - 1], params.currencyOut);
                amountIn = uint128(
                    -_swap(poolKey, !oneForZero, int256(int128(params.amountOut)), 0, params.path[i - 1].hookData)
                );

                params.amountOut = amountIn;
                params.currencyOut = params.path[i - 1].intermediateCurrency;
            }
            if (amountIn > params.amountInMaximum) revert TooMuchRequested();
        }
    }

    function _swap(
        PoolKey memory poolKey,
        bool zeroForOne,
        int256 amountSpecified,
        uint160 sqrtPriceLimitX96,
        bytes memory hookData
    ) private returns (int128 reciprocalAmount) {
        BalanceDelta delta = poolManager.swap(
            poolKey,
            IPoolManager.SwapParams(
                zeroForOne,
                amountSpecified,
                sqrtPriceLimitX96 == 0
                    ? (zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1)
                    : sqrtPriceLimitX96
            ),
            hookData
        );

        reciprocalAmount = (zeroForOne == amountSpecified < 0) ? delta.amount1() : delta.amount0();
    }

    function _getPoolAndSwapDirection(PathKey memory params, Currency currencyIn)
        private
        pure
        returns (PoolKey memory poolKey, bool zeroForOne)
    {
        (Currency currency0, Currency currency1) = currencyIn < params.intermediateCurrency
            ? (currencyIn, params.intermediateCurrency)
            : (params.intermediateCurrency, currencyIn);

        zeroForOne = currencyIn == currency0;
        poolKey = PoolKey(currency0, currency1, params.fee, params.tickSpacing, params.hooks);
    }

    function _take(Currency currency, address recipient) private {
        int256 delta = poolManager.currencyDelta(address(this), currency);
        if (delta < 0) revert();

        poolManager.take(currency, recipient, uint256(delta));
    }

    function _payAndSettle(Currency currency, address payer) private {
        int256 delta = poolManager.currencyDelta(address(this), currency);
        if (delta > 0) revert();

        poolManager.sync(currency);
        _pay(Currency.unwrap(currency), payer, address(poolManager), uint256(-delta));
        poolManager.settle(currency);
    }

    function _pay(address token, address payer, address recipient, uint256 amount) internal virtual;
}
