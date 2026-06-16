// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";

import {PathKey} from "./libraries/PathKey.sol";
import {CalldataDecoder} from "./libraries/CalldataDecoder.sol";
import {IV4Router} from "./interfaces/IV4Router.sol";
import {BaseActionsRouter} from "./base/BaseActionsRouter.sol";
import {DeltaResolver} from "./base/DeltaResolver.sol";
import {Actions} from "./libraries/Actions.sol";
import {ActionConstants} from "./libraries/ActionConstants.sol";
import {BipsLibrary} from "./libraries/BipsLibrary.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

/// @title UniswapV4Router
/// @notice Abstract contract that contains all internal logic needed for routing through Uniswap v4 pools
/// @dev the entry point to executing actions in this contract is calling `BaseActionsRouter._executeActions`
/// An inheriting contract should call _executeActions at the point that they wish actions to be executed
abstract contract V4Router is IV4Router, BaseActionsRouter, DeltaResolver {
    using SafeCast for *;
    using CalldataDecoder for bytes;
    using BipsLibrary for uint256;

    uint256 private constant PRECISION = 1e36;

    constructor(IPoolManager _poolManager) BaseActionsRouter(_poolManager) {}

    function _handleAction(uint256 action, bytes calldata params) internal virtual override {
        // swap actions and payment actions in different blocks for gas efficiency
        if (action < Actions.SETTLE) {
            if (action == Actions.SWAP_EXACT_IN) {
                IV4Router.ExactInputParams calldata swapParams = params.decodeSwapExactInParams();
                _swapExactInput(swapParams);
                return;
            } else if (action == Actions.SWAP_EXACT_IN_SINGLE) {
                IV4Router.ExactInputSingleParams calldata swapParams = params.decodeSwapExactInSingleParams();
                _swapExactInputSingle(swapParams);
                return;
            } else if (action == Actions.SWAP_EXACT_OUT) {
                IV4Router.ExactOutputParams calldata swapParams = params.decodeSwapExactOutParams();
                _swapExactOutput(swapParams);
                return;
            } else if (action == Actions.SWAP_EXACT_OUT_SINGLE) {
                IV4Router.ExactOutputSingleParams calldata swapParams = params.decodeSwapExactOutSingleParams();
                _swapExactOutputSingle(swapParams);
                return;
            }
        } else {
            if (action == Actions.SETTLE_ALL) {
                (Currency currency, uint256 maxAmount) = params.decodeCurrencyAndUint256();
                uint256 amount = _getFullDebt(currency);
                if (amount > maxAmount) revert V4TooMuchRequested(maxAmount, amount);
                _settle(currency, msgSender(), amount);
                return;
            } else if (action == Actions.TAKE_ALL) {
                (Currency currency, uint256 minAmount) = params.decodeCurrencyAndUint256();
                uint256 amount = _getFullCredit(currency);
                if (amount < minAmount) revert V4TooLittleReceived(minAmount, amount);
                _take(currency, msgSender(), amount);
                return;
            } else if (action == Actions.SETTLE) {
                (Currency currency, uint256 amount, bool payerIsUser) = params.decodeCurrencyUint256AndBool();
                _settle(currency, _mapPayer(payerIsUser), _mapSettleAmount(amount, currency));
                return;
            } else if (action == Actions.TAKE) {
                (Currency currency, address recipient, uint256 amount) = params.decodeCurrencyAddressAndUint256();
                _take(currency, _mapRecipient(recipient), _mapTakeAmount(amount, currency));
                return;
            } else if (action == Actions.TAKE_PORTION) {
                (Currency currency, address recipient, uint256 bips) = params.decodeCurrencyAddressAndUint256();
                _take(currency, _mapRecipient(recipient), _getFullCredit(currency).calculatePortion(bips));
                return;
            }
        }
        revert UnsupportedAction(action);
    }

    function _swapExactInputSingle(IV4Router.ExactInputSingleParams calldata params) private {
        uint128 amountIn = params.amountIn;
        if (amountIn == ActionConstants.OPEN_DELTA) {
            amountIn =
                _getFullCredit(params.zeroForOne ? params.poolKey.currency0 : params.poolKey.currency1).toUint128();
        }
        uint128 amountOut = _swapOutput(
            _swap(params.poolKey, params.zeroForOne, -int256(uint256(amountIn)), params.hookData), params.zeroForOne
        );
        if (amountOut < params.amountOutMinimum) revert V4TooLittleReceived(params.amountOutMinimum, amountOut);
        if (params.minHopPriceX36 != 0) {
            uint256 priceX36 = uint256(amountOut) * PRECISION / amountIn;
            if (priceX36 < params.minHopPriceX36) {
                revert V4TooLittleReceivedPerHopSingle(params.minHopPriceX36, priceX36);
            }
        }
    }

    function _swapExactInput(IV4Router.ExactInputParams calldata params) private {
        unchecked {
            // Caching for gas savings
            uint256 pathLength = params.path.length;
            uint128 amountOut;
            Currency currencyIn = params.currencyIn;
            uint128 amountIn = params.amountIn;
            if (amountIn == ActionConstants.OPEN_DELTA) amountIn = _getFullCredit(currencyIn).toUint128();
            PathKey calldata pathKey;

            uint256 perHopPriceLength = params.minHopPriceX36.length;
            if (perHopPriceLength != 0 && perHopPriceLength != pathLength) revert InvalidHopPriceLength();

            for (uint256 i = 0; i < pathLength; i++) {
                pathKey = params.path[i];
                (PoolKey memory poolKey, bool zeroForOne) = pathKey.getPoolAndSwapDirection(currencyIn);
                // The output delta will always be positive, except for when interacting with certain hook pools
                amountOut =
                    _swapOutput(_swap(poolKey, zeroForOne, -int256(uint256(amountIn)), pathKey.hookData), zeroForOne);

                if (perHopPriceLength != 0) {
                    uint256 priceX36 = amountOut * PRECISION / amountIn;
                    uint256 minPrice = params.minHopPriceX36[i];
                    if (priceX36 < minPrice) revert V4TooLittleReceivedPerHop(i, minPrice, priceX36);
                }

                amountIn = amountOut;
                currencyIn = pathKey.intermediateCurrency;
            }

            if (amountOut < params.amountOutMinimum) revert V4TooLittleReceived(params.amountOutMinimum, amountOut);
        }
    }

    function _swapExactOutputSingle(IV4Router.ExactOutputSingleParams calldata params) private {
        uint128 amountOut = params.amountOut;
        if (amountOut == ActionConstants.OPEN_DELTA) {
            amountOut =
                _getFullDebt(params.zeroForOne ? params.poolKey.currency1 : params.poolKey.currency0).toUint128();
        }
        BalanceDelta delta = _swap(params.poolKey, params.zeroForOne, int256(uint256(amountOut)), params.hookData);
        uint128 amountIn = _swapInput(delta, params.zeroForOne);
        if (amountIn > params.amountInMaximum) revert V4TooMuchRequested(params.amountInMaximum, amountIn);
        if (params.minHopPriceX36 != 0) {
            // price the REALIZED output against the actual input: the pool can deliver less than the
            // requested amountOut, so using amountOut here would overstate the execution price
            uint256 priceX36 = uint256(_swapOutput(delta, params.zeroForOne)) * PRECISION / amountIn;
            if (priceX36 < params.minHopPriceX36) {
                revert V4TooMuchRequestedPerHopSingle(params.minHopPriceX36, priceX36);
            }
        }
    }

    function _swapExactOutput(IV4Router.ExactOutputParams calldata params) private {
        unchecked {
            // Caching for gas savings
            uint256 pathLength = params.path.length;
            uint128 amountIn;
            uint128 amountOut = params.amountOut;
            Currency currencyOut = params.currencyOut;
            PathKey calldata pathKey;

            if (amountOut == ActionConstants.OPEN_DELTA) {
                amountOut = _getFullDebt(currencyOut).toUint128();
            }

            uint256 perHopPriceLength = params.minHopPriceX36.length;
            if (perHopPriceLength != 0 && perHopPriceLength != pathLength) revert InvalidHopPriceLength();

            for (uint256 i = pathLength; i > 0; i--) {
                pathKey = params.path[i - 1];
                (PoolKey memory poolKey, bool oneForZero) = pathKey.getPoolAndSwapDirection(currencyOut);
                // The output delta will always be negative, except for when interacting with certain hook pools
                BalanceDelta delta = _swap(poolKey, !oneForZero, int256(uint256(amountOut)), pathKey.hookData);
                amountIn = _swapInput(delta, !oneForZero);

                if (perHopPriceLength != 0) {
                    // price the REALIZED output (which can be a partial fill) against the actual input
                    uint256 priceX36 = uint256(_swapOutput(delta, !oneForZero)) * PRECISION / amountIn;
                    uint256 minPrice = params.minHopPriceX36[i - 1];
                    if (priceX36 < minPrice) revert V4TooMuchRequestedPerHop(i - 1, minPrice, priceX36);
                }
                amountOut = amountIn;
                currencyOut = pathKey.intermediateCurrency;
            }
            if (amountIn > params.amountInMaximum) revert V4TooMuchRequested(params.amountInMaximum, amountIn);
        }
    }

    function _swap(PoolKey memory poolKey, bool zeroForOne, int256 amountSpecified, bytes calldata hookData)
        private
        returns (BalanceDelta delta)
    {
        // for protection of exactOut swaps, sqrtPriceLimit is not exposed as a feature in this contract
        delta = poolManager.swap(
            poolKey,
            SwapParams(
                zeroForOne, amountSpecified, zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            ),
            hookData
        );
    }

    /// @notice The positive input amount a swap consumed, derived from its balance delta.
    /// @dev The spent currency's delta is negative (owed to the pool), so negate it to a positive amount.
    function _swapInput(BalanceDelta delta, bool zeroForOne) private pure returns (uint128) {
        return (uint256(-int256(zeroForOne ? delta.amount0() : delta.amount1()))).toUint128();
    }

    /// @notice The positive output amount a swap produced, derived from its balance delta. For an
    ///         exact-output swap this is the REALIZED output, which can be less than the requested
    ///         amount when the pool lacks the liquidity to fill it before the price limit.
    function _swapOutput(BalanceDelta delta, bool zeroForOne) private pure returns (uint128) {
        return (zeroForOne ? delta.amount1() : delta.amount0()).toUint128();
    }
}
