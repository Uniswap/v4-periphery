// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";

import {PathKey, PathKeyLib} from "./libraries/PathKey.sol";
import {CalldataDecoder} from "./libraries/CalldataDecoder.sol";
import {BipsLibrary} from "./libraries/BipsLibrary.sol";
import {IV4Router} from "./interfaces/IV4Router.sol";
import {BaseActionsRouter} from "./base/BaseActionsRouter.sol";
import {DeltaResolver} from "./base/DeltaResolver.sol";
import {Actions} from "./libraries/Actions.sol";
import {SafeCastTemp} from "./libraries/SafeCast.sol";

/// @title UniswapV4Router
/// @notice Abstract contract that contains all internal logic needed for routing through Uniswap V4 pools
/// @dev the entry point to executing actions in this contract is calling `BaseActionsRouter._executeActions`
/// An inheriting contract should call _executeActions at the point that they wish actions to be executed
abstract contract V4Router is IV4Router, BaseActionsRouter, DeltaResolver {
    using SafeCastTemp for *;
    using SafeCast for *;
    using PathKeyLib for PathKey;
    using CalldataDecoder for bytes;
    using BipsLibrary for uint256;

    constructor(IPoolManager _poolManager) BaseActionsRouter(_poolManager) {}

    // TODO native support !!
    function _handleAction(uint256 action, bytes calldata params) internal override {
        // swap actions and payment actions in different blocks for gas efficiency
        if (action < Actions.SETTLE_ALL) {
            if (action == Actions.SWAP_EXACT_IN) {
                IV4Router.ExactInputParams calldata swapParams = params.decodeSwapExactInParams();
                _swapExactInput(swapParams);
            } else if (action == Actions.SWAP_EXACT_IN_SINGLE) {
                IV4Router.ExactInputSingleParams calldata swapParams = params.decodeSwapExactInSingleParams();
                _swapExactInputSingle(swapParams);
            } else if (action == Actions.SWAP_EXACT_OUT) {
                IV4Router.ExactOutputParams calldata swapParams = params.decodeSwapExactOutParams();
                _swapExactOutput(swapParams);
            } else if (action == Actions.SWAP_EXACT_OUT_SINGLE) {
                IV4Router.ExactOutputSingleParams calldata swapParams = params.decodeSwapExactOutSingleParams();
                _swapExactOutputSingle(swapParams);
            } else {
                revert UnsupportedAction(action);
            }
        } else {
            if (action == Actions.SETTLE_ALL) {
                Currency currency = params.decodeCurrency();
                // TODO should it have a maxAmountOut added slippage protection?
                _settle(currency, _msgSender(), _getFullSettleAmount(currency));
            } else if (action == Actions.SETTLE) {
                (Currency currency, uint256 amount, bool payerIsUser) = params.decodeCurrencyUint256AndBool();
                _settle(currency, _mapPayer(payerIsUser), _mapSettleAmount(amount, currency));
            } else if (action == Actions.TAKE_ALL) {
                (Currency currency, address recipient) = params.decodeCurrencyAndAddress();
                uint256 amount = _getFullTakeAmount(currency);
                _take(currency, _mapRecipient(recipient), amount);
            } else if (action == Actions.TAKE_PORTION) {
                (Currency currency, address recipient, uint256 bips) = params.decodeCurrencyAddressAndUint256();
                _take(currency, _mapRecipient(recipient), _getFullTakeAmount(currency).calculatePortion(bips));
            } else {
                revert UnsupportedAction(action);
            }
        }
    }

    function _swapExactInputSingle(IV4Router.ExactInputSingleParams calldata params) private {
        uint128 amountIn =
            _mapInputAmount(params.amountIn, params.zeroForOne ? params.poolKey.currency0 : params.poolKey.currency1);
        uint128 amountOut = _swap(
            params.poolKey, params.zeroForOne, int256(-int128(amountIn)), params.sqrtPriceLimitX96, params.hookData
        ).toUint128();
        if (amountOut < params.amountOutMinimum) revert TooLittleReceived();
    }

    function _swapExactInput(IV4Router.ExactInputParams calldata params) private {
        unchecked {
            // Caching for gas savings
            uint256 pathLength = params.path.length;
            uint128 amountOut;
            Currency currencyIn = params.currencyIn;
            uint128 amountIn = _mapInputAmount(params.amountIn, currencyIn);
            PathKey calldata pathKey;

            for (uint256 i = 0; i < pathLength; i++) {
                pathKey = params.path[i];
                (PoolKey memory poolKey, bool zeroForOne) = pathKey.getPoolAndSwapDirection(currencyIn);
                // The output delta will always be positive, except for when interacting with certain hook pools
                amountOut = _swap(poolKey, zeroForOne, -int256(uint256(amountIn)), 0, pathKey.hookData).toUint128();

                amountIn = amountOut;
                currencyIn = pathKey.intermediateCurrency;
            }

            if (amountOut < params.amountOutMinimum) revert TooLittleReceived();
        }
    }

    function _swapExactOutputSingle(IV4Router.ExactOutputSingleParams calldata params) private {
        uint128 amountIn = (
            -_swap(
                params.poolKey,
                params.zeroForOne,
                int256(int128(params.amountOut)),
                params.sqrtPriceLimitX96,
                params.hookData
            )
        ).toUint128();
        if (amountIn > params.amountInMaximum) revert TooMuchRequested();
    }

    function _swapExactOutput(IV4Router.ExactOutputParams calldata params) private {
        unchecked {
            // Caching for gas savings
            uint256 pathLength = params.path.length;
            uint128 amountIn;
            uint128 amountOut = params.amountOut;
            Currency currencyOut = params.currencyOut;
            PathKey calldata pathKey;

            for (uint256 i = pathLength; i > 0; i--) {
                pathKey = params.path[i - 1];
                (PoolKey memory poolKey, bool oneForZero) = pathKey.getPoolAndSwapDirection(currencyOut);
                // The output delta will always be negative, except for when interacting with certain hook pools
                amountIn = (-_swap(poolKey, !oneForZero, int256(uint256(amountOut)), 0, pathKey.hookData)).toUint128();

                amountOut = amountIn;
                currencyOut = pathKey.intermediateCurrency;
            }
            if (amountIn > params.amountInMaximum) revert TooMuchRequested();
        }
    }

    function _swap(
        PoolKey memory poolKey,
        bool zeroForOne,
        int256 amountSpecified,
        uint160 sqrtPriceLimitX96,
        bytes calldata hookData
    ) private returns (int128 reciprocalAmount) {
        unchecked {
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
    }
}
