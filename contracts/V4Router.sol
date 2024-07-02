// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
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

    IPoolManager immutable poolManager;

    constructor(IPoolManager _poolManager) {
        poolManager = _poolManager;
    }

    // @dev The contract inheriting from this contract, and calling _v4Swap must set the payer and recipient securely.
    // Allowing any payer or recipient to be passed in could allow users to steal each others' tokens.
    function _v4Swap(SwapType swapType, PaymentAddresses memory paymentAddresses, bytes memory params) internal {
        poolManager.unlock(abi.encode(SwapInfo(swapType, paymentAddresses, params)));
    }

    /// @inheritdoc IUnlockCallback
    function unlockCallback(bytes calldata encodedSwapInfo) external override returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();

        SwapInfo memory swapInfo = abi.decode(encodedSwapInfo, (SwapInfo));

        if (swapInfo.swapType == SwapType.ExactInput) {
            _swapExactInput(abi.decode(swapInfo.params, (IV4Router.ExactInputParams)), swapInfo.paymentAddresses);
        } else if (swapInfo.swapType == SwapType.ExactInputSingle) {
            _swapExactInputSingle(
                abi.decode(swapInfo.params, (IV4Router.ExactInputSingleParams)), swapInfo.paymentAddresses
            );
        } else if (swapInfo.swapType == SwapType.ExactOutput) {
            _swapExactOutput(abi.decode(swapInfo.params, (IV4Router.ExactOutputParams)), swapInfo.paymentAddresses);
        } else if (swapInfo.swapType == SwapType.ExactOutputSingle) {
            _swapExactOutputSingle(
                abi.decode(swapInfo.params, (IV4Router.ExactOutputSingleParams)), swapInfo.paymentAddresses
            );
        } else {
            revert InvalidSwapType();
        }

        return bytes("");
    }

    function _swapExactInputSingle(
        IV4Router.ExactInputSingleParams memory params,
        PaymentAddresses memory paymentAddresses
    ) private {
        _swap(
            params.poolKey,
            params.zeroForOne,
            int256(-int128(params.amountIn)),
            params.sqrtPriceLimitX96,
            paymentAddresses,
            true,
            true,
            params.hookData
        );
    }

    function _swapExactInput(IV4Router.ExactInputParams memory params, PaymentAddresses memory paymentAddresses)
        private
    {
        unchecked {
            uint256 pathLength = params.path.length;
            uint128 amountOut;

            for (uint256 i = 0; i < pathLength; i++) {
                (PoolKey memory poolKey, bool zeroForOne) = _getPoolAndSwapDirection(params.path[i], params.currencyIn);
                amountOut = uint128(
                    _swap(
                        poolKey,
                        zeroForOne,
                        int256(-int128(params.amountIn)),
                        0,
                        paymentAddresses,
                        i == 0,
                        i == pathLength - 1,
                        params.path[i].hookData
                    )
                );

                params.amountIn = amountOut;
                params.currencyIn = params.path[i].intermediateCurrency;
            }

            if (amountOut < params.amountOutMinimum) revert TooLittleReceived();
        }
    }

    function _swapExactOutputSingle(
        IV4Router.ExactOutputSingleParams memory params,
        PaymentAddresses memory paymentAddresses
    ) private {
        _swap(
            params.poolKey,
            params.zeroForOne,
            int256(int128(params.amountOut)),
            params.sqrtPriceLimitX96,
            paymentAddresses,
            true,
            true,
            params.hookData
        );
    }

    function _swapExactOutput(IV4Router.ExactOutputParams memory params, PaymentAddresses memory paymentAddresses)
        private
    {
        unchecked {
            uint256 pathLength = params.path.length;
            uint128 amountIn;

            for (uint256 i = pathLength; i > 0; i--) {
                (PoolKey memory poolKey, bool oneForZero) =
                    _getPoolAndSwapDirection(params.path[i - 1], params.currencyOut);
                amountIn = uint128(
                    -_swap(
                        poolKey,
                        !oneForZero,
                        int256(int128(params.amountOut)),
                        0,
                        paymentAddresses,
                        i == 1,
                        i == pathLength,
                        params.path[i - 1].hookData
                    )
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
        PaymentAddresses memory paymentAddresses,
        bool settle,
        bool take,
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

        if (zeroForOne) {
            reciprocalAmount = amountSpecified < 0 ? delta.amount1() : delta.amount0();
            if (settle) _payAndSettle(poolKey.currency0, paymentAddresses.payer, delta.amount0());
            if (take) poolManager.take(poolKey.currency1, paymentAddresses.recipient, uint128(delta.amount1()));
        } else {
            reciprocalAmount = amountSpecified < 0 ? delta.amount0() : delta.amount1();
            if (settle) _payAndSettle(poolKey.currency1, paymentAddresses.payer, delta.amount1());
            if (take) poolManager.take(poolKey.currency0, paymentAddresses.recipient, uint128(delta.amount0()));
        }
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

    function _payAndSettle(Currency currency, address payer, int128 settleAmount) private {
        poolManager.sync(currency);
        _pay(Currency.unwrap(currency), payer, uint256(uint128(-settleAmount)));
        poolManager.settle(currency);
    }

    function _pay(address token, address payer, uint256 amount) internal virtual;
}
