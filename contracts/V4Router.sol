// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import "forge-std/console2.sol";
import {Hooks} from "@uniswap/v4-core/contracts/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/contracts/interfaces/IPoolManager.sol";
import {ILockCallback} from "@uniswap/v4-core/contracts/interfaces/callback/ILockCallback.sol";
import {BalanceDelta} from "@uniswap/v4-core/contracts/types/BalanceDelta.sol";
import {PoolKey} from "@uniswap/v4-core/contracts/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/contracts/types/Currency.sol";
import {TickMath} from "@uniswap/v4-core/contracts/libraries/TickMath.sol";
import {IHooks} from "@uniswap/v4-core/contracts/interfaces/IHooks.sol";
import {PathKey} from "./libraries/PathKey.sol";
import {IV4Router} from "./interfaces/IV4Router.sol";

/// @title UniswapV4Routing
/// @notice Abstract contract that contains all internal logic needed for routing through Uniswap V4 pools
abstract contract V4Router is IV4Router, ILockCallback {
    using CurrencyLibrary for Currency;

    IPoolManager immutable poolManager;

    /// @dev Only the pool manager may call this function
    modifier poolManagerOnly() {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        _;
    }

    constructor(IPoolManager _poolManager) {
        poolManager = _poolManager;
    }

    function _v4Swap(SwapType swapType, bytes memory params) internal {
        poolManager.lock(abi.encode(SwapInfo(swapType, msg.sender, params)));
    }

    /// @inheritdoc ILockCallback
    function lockAcquired(bytes calldata encodedSwapInfo) external override poolManagerOnly returns (bytes memory) {
        SwapInfo memory swapInfo = abi.decode(encodedSwapInfo, (SwapInfo));

        if (swapInfo.swapType == SwapType.ExactInput) {
            _swapExactInput(abi.decode(swapInfo.params, (ExactInputParams)), swapInfo.msgSender);
        } else if (swapInfo.swapType == SwapType.ExactInputSingle) {
            _swapExactInputSingle(abi.decode(swapInfo.params, (ExactInputSingleParams)), swapInfo.msgSender);
        } else if (swapInfo.swapType == SwapType.ExactOutput) {
            // console2.log("===acquired ===");
            // console2.logBytes(swapInfo.params);
            // ExactOutputParams memory decoded = abi.decode(swapInfo.params, (ExactOutputParams));
            // console2.logAddress(Currency.unwrap(decoded.currencyOut)); // CurrencyOut
            // console2.logBytes16(bytes16(decoded.amountOut)); // AmountOut
            // console2.logBytes16(bytes16(decoded.amountInMaximum)); // AmountInMaximum
            // console2.log(
            //     "decoded recipient: %s, amountOut: %s, amountInMaximum: %s",
            //     decoded.recipient,
            //     decoded.amountOut,
            //     uint256(decoded.amountInMaximum)
            // );
            _swapExactOutput(abi.decode(swapInfo.params, (ExactOutputParams)), swapInfo.msgSender);
        } else if (swapInfo.swapType == SwapType.ExactOutputSingle) {
            _swapExactOutputSingle(abi.decode(swapInfo.params, (ExactOutputSingleParams)), swapInfo.msgSender);
        } else {
            revert InvalidSwapType();
        }

        return bytes("");
    }

    function _swapExactInputSingle(ExactInputSingleParams memory params, address msgSender) private {
        _swapExactPrivate(
            params.poolKey,
            params.zeroForOne,
            int256(int128(params.amountIn)),
            params.sqrtPriceLimitX96,
            msgSender,
            true,
            true,
            params.hookData
        );
    }

    function _swapExactInput(ExactInputParams memory params, address msgSender) private {
        unchecked {
            uint256 pathLength = params.path.length;
            uint128 amountOut;

            for (uint256 i = 0; i < pathLength; i++) {
                (PoolKey memory poolKey, bool zeroForOne) = _getPoolAndSwapDirection(params.path[i], params.currencyIn);
                amountOut = uint128(
                    -_swapExactPrivate(
                        poolKey,
                        zeroForOne,
                        int256(int128(params.amountIn)),
                        0,
                        msgSender,
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

    function _swapExactOutputSingle(ExactOutputSingleParams memory params, address msgSender) private {
        _swapExactPrivate(
            params.poolKey,
            params.zeroForOne,
            -int256(int128(params.amountOut)),
            params.sqrtPriceLimitX96,
            msgSender,
            true,
            true,
            params.hookData
        );
    }

    function _swapExactOutput(ExactOutputParams memory params, address msgSender) private {
        unchecked {
            uint256 pathLength = params.path.length;
            uint128 amountIn;

            for (uint256 i = pathLength; i > 0; i--) {
                (PoolKey memory poolKey, bool oneForZero) =
                    _getPoolAndSwapDirection(params.path[i - 1], params.currencyOut);
                amountIn = uint128(
                    _swapExactPrivate(
                        poolKey,
                        !oneForZero,
                        -int256(int128(params.amountOut)),
                        0,
                        msgSender,
                        i == 1,
                        i == pathLength,
                        params.path[i - 1].hookData
                    )
                );

                params.amountOut = amountIn;
                params.currencyOut = params.path[i - 1].intermediateCurrency;
            }
            console2.log("amountIn: %s; max: %s", amountIn, params.amountInMaximum);
            if (amountIn > params.amountInMaximum) revert TooMuchRequested();
        }
    }

    function _swapExactPrivate(
        PoolKey memory poolKey,
        bool zeroForOne,
        int256 amountSpecified,
        uint160 sqrtPriceLimitX96,
        address msgSender,
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
                    ? (zeroForOne ? TickMath.MIN_SQRT_RATIO + 1 : TickMath.MAX_SQRT_RATIO - 1)
                    : sqrtPriceLimitX96
            ),
            hookData
        );

        if (zeroForOne) {
            reciprocalAmount = amountSpecified > 0 ? delta.amount1() : delta.amount0();
            if (settle) _payAndSettle(poolKey.currency0, msgSender, delta.amount0());
            if (take) poolManager.take(poolKey.currency1, msgSender, uint128(-delta.amount1()));
        } else {
            reciprocalAmount = amountSpecified > 0 ? delta.amount0() : delta.amount1();
            if (settle) _payAndSettle(poolKey.currency1, msgSender, delta.amount1());
            if (take) poolManager.take(poolKey.currency0, msgSender, uint128(-delta.amount0()));
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

    function _payAndSettle(Currency currency, address msgSender, int128 settleAmount) private {
        _pay(Currency.unwrap(currency), msgSender, address(poolManager), uint256(uint128(settleAmount)));
        poolManager.settle(currency);
    }

    function _pay(address token, address payer, address recipient, uint256 amount) internal virtual;
}
