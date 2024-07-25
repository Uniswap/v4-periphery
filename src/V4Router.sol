// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

import {PathKey, PathKeyLib} from "./libraries/PathKey.sol";
import {CalldataBytesLib} from "./libraries/CalldataBytesLib.sol";
import {IV4Router} from "./interfaces/IV4Router.sol";
import {BaseActionsRouter} from "./base/BaseActionsRouter.sol";
import {Actions} from "./libraries/Actions.sol";

/// @title UniswapV4Router
/// @notice Abstract contract that contains all internal logic needed for routing through Uniswap V4 pools
/// @dev the entry point to executing actions in this contract is calling `BaseActionsRouter._executeActions`
/// An inheriting contract should call _executeActions at the point that they wish actions to be executed
abstract contract V4Router is IV4Router, BaseActionsRouter {
    using PathKeyLib for PathKey;
    using CurrencyLibrary for Currency;
    using TransientStateLibrary for IPoolManager;
    using CalldataBytesLib for bytes;

    constructor(IPoolManager poolManager) BaseActionsRouter(poolManager) {}

    /// @inheritdoc IV4Router
    uint256 public constant override ENTIRE_OPEN_DELTA = 0;

    function _handleAction(uint256 action, bytes calldata params) internal override {
        // swap actions and payment actions in different blocks for gas efficiency
        if (action < Actions.SETTLE) {
            if (action == Actions.SWAP_EXACT_IN) {
                _swapExactInput(abi.decode(params, (IV4Router.ExactInputParams)));
            } else if (action == Actions.SWAP_EXACT_IN_SINGLE) {
                _swapExactInputSingle(abi.decode(params, (IV4Router.ExactInputSingleParams)));
            } else if (action == Actions.SWAP_EXACT_OUT) {
                _swapExactOutput(abi.decode(params, (IV4Router.ExactOutputParams)));
            } else if (action == Actions.SWAP_EXACT_OUT_SINGLE) {
                _swapExactOutputSingle(abi.decode(params, (IV4Router.ExactOutputSingleParams)));
            } else {
                revert UnsupportedAction(action);
            }
        } else {
            if (action == Actions.SETTLE) {
                // equivalent: abi.decode(params, (Currency))
                Currency currency;
                uint256 amount;
                assembly ("memory-safe") {
                    currency := calldataload(params.offset)
                    amount := calldataload(add(params.offset, 0x20))
                }

                // TODO support address(this) paying too
                _payAndSettle(currency, _msgSender(), amount);
            } else if (action == Actions.TAKE) {
                // equivalent: abi.decode(params, (Currency, address, uint256))
                Currency currency;
                address recipient;
                uint256 amount;
                assembly ("memory-safe") {
                    currency := calldataload(params.offset)
                    recipient := calldataload(add(params.offset, 0x20))
                    amount := calldataload(add(params.offset, 0x40))
                }

                // TODO should _take have a minAmountOut added slippage check?
                _take(currency, recipient, amount);
            } else {
                revert UnsupportedAction(action);
            }
        }
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
            // Caching for gas savings
            uint256 pathLength = params.path.length;
            uint128 amountOut;
            uint128 amountIn = params.amountIn;
            Currency currencyIn = params.currencyIn;
            PathKey memory pathKey;

            for (uint256 i = 0; i < pathLength; i++) {
                pathKey = params.path[i];
                (PoolKey memory poolKey, bool zeroForOne) = pathKey.getPoolAndSwapDirection(currencyIn);
                amountOut = uint128(_swap(poolKey, zeroForOne, int256(-int128(amountIn)), 0, pathKey.hookData));

                amountIn = amountOut;
                currencyIn = pathKey.intermediateCurrency;
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
            // Caching for gas savings
            uint256 pathLength = params.path.length;
            uint128 amountIn;
            uint128 amountOut = params.amountOut;
            Currency currencyOut = params.currencyOut;
            PathKey memory pathKey;

            for (uint256 i = pathLength; i > 0; i--) {
                pathKey = params.path[i - 1];
                (PoolKey memory poolKey, bool oneForZero) = pathKey.getPoolAndSwapDirection(currencyOut);
                amountIn = uint128(-_swap(poolKey, !oneForZero, int256(int128(amountOut)), 0, pathKey.hookData));

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
        bytes memory hookData
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

    // TODO use DeltaResolver
    function _take(Currency currency, address recipient, uint256 amount) private {
        if (amount == ENTIRE_OPEN_DELTA) {
            int256 delta = poolManager.currencyDelta(address(this), currency);
            if (delta < 0) revert InvalidDeltaForAction();
            amount = uint256(delta);
        }
        poolManager.take(currency, recipient, amount);
    }

    // TODO native support !!
    // TODO should it have a maxAmountOut added slippage protection?
    // TODO use DeltaResolver
    function _payAndSettle(Currency currency, address payer, uint256 amount) private {
        if (amount == ENTIRE_OPEN_DELTA) {
            int256 delta = poolManager.currencyDelta(address(this), currency);
            if (delta > 0) revert InvalidDeltaForAction();
            amount = uint256(-delta);
        }

        poolManager.sync(currency);
        _pay(Currency.unwrap(currency), payer, address(poolManager), amount);
        poolManager.settle();
    }

    function _pay(address token, address payer, address recipient, uint256 amount) internal virtual;
}