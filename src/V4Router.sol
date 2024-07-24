// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PathKey} from "./libraries/PathKey.sol";
import {CalldataBytesLib} from "./libraries/CalldataBytesLib.sol";
import {IV4Router} from "./interfaces/IV4Router.sol";
import {BaseActionsRouter} from "./base/BaseActionsRouter.sol";
import {Actions} from "./libraries/Actions.sol";

/// @title UniswapV4Router
/// @notice Abstract contract that contains all internal logic needed for routing through Uniswap V4 pools
/// @dev the entry point to executing actions in this contract is calling `BaseActionsRouter._executeActions`
/// An inheriting contract should call _executeActions at the point that they wish actions to be executed
abstract contract V4Router is IV4Router, BaseActionsRouter {
    using CurrencyLibrary for Currency;
    using TransientStateLibrary for IPoolManager;
    using CalldataBytesLib for bytes;

    constructor(IPoolManager poolManager) BaseActionsRouter(poolManager) {}

    function _handleAction(uint256 action, bytes calldata params) internal override {
        // swap actions and payment actions in different blocks for gas efficiency
        if (action < 0x10) {
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
                assembly ("memory-safe") {
                    currency := calldataload(params.offset)
                }

                // TODO support address(this) paying too
                _payAndSettle(currency, _msgSender());
            } else if (action == Actions.TAKE) {
                // equivalent: abi.decode(params, (Currency, address))
                Currency currency;
                address recipient;
                assembly ("memory-safe") {
                    currency := calldataload(params.offset)
                    recipient := calldataload(add(params.offset, 0x20))
                }

                // TODO add min amount??
                _take(currency, recipient);
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

    // TODO native support !!
    // TODO use currency settle take library
    function _payAndSettle(Currency currency, address payer) private {
        int256 delta = poolManager.currencyDelta(address(this), currency);
        if (delta > 0) revert();

        poolManager.sync(currency);
        _pay(Currency.unwrap(currency), payer, address(poolManager), uint256(-delta));
        poolManager.settle();
    }

    function _pay(address token, address payer, address recipient, uint256 amount) internal virtual;
}
