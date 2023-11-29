// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {PoolKey} from "@uniswap/v4-core/contracts/types/PoolKey.sol";
import {BalanceDelta} from "@uniswap/v4-core/contracts/types/BalanceDelta.sol";
import {ILockCallback} from "@uniswap/v4-core/contracts/interfaces/callback/ILockCallback.sol";
import {TickMath} from "@uniswap/v4-core/contracts/libraries/TickMath.sol";
import {BalanceDelta} from "@uniswap/v4-core/contracts/types/BalanceDelta.sol";
import {IPoolManager} from "@uniswap/v4-core/contracts/interfaces/IPoolManager.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/contracts/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/contracts/types/PoolId.sol";

import {LiquidityAmounts} from "../libraries/LiquidityAmounts.sol";
import {PeripheryImmutableState} from "./PeripheryImmutableState.sol";
import {PeripheryPayments} from "./PeripheryPayments.sol";

/// @title Liquidity management functions
/// @notice Internal functions for safely managing liquidity in Uniswap V4
abstract contract LiquidityManagement is ILockCallback, PeripheryImmutableState, PeripheryPayments {
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;

    error PriceSlippage();

    enum CallbackType {AddLiquidity}

    struct CallbackData {
        CallbackType callbackType;
        address sender;
        bytes params;
    }

    struct AddLiquidityParams {
        PoolKey poolKey;
        int24 tickLower;
        int24 tickUpper;
        uint256 amount0Desired;
        uint256 amount1Desired;
        uint256 amount0Min;
        uint256 amount1Min;
        bytes hookData;
    }

    /// @notice Add liquidity to an initialized pool
    function addLiquidity(AddLiquidityParams memory params)
        internal
        returns (uint128 liquidity, uint256 amount0, uint256 amount1)
    {
        (liquidity, amount0, amount1) = abi.decode(
            poolManager.lock(abi.encode(CallbackData(CallbackType.AddLiquidity, msg.sender, abi.encode(params)))),
            (uint128, uint256, uint256)
        );
    }

    function addLiquidityCallback(AddLiquidityParams memory params)
        internal
        returns (uint128 liquidity, BalanceDelta delta)
    {
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(params.poolKey.toId());
        uint160 sqrtRatioAX96 = TickMath.getSqrtRatioAtTick(params.tickLower);
        uint160 sqrtRatioBX96 = TickMath.getSqrtRatioAtTick(params.tickUpper);
        liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96, sqrtRatioAX96, sqrtRatioBX96, params.amount0Desired, params.amount1Desired
        );
        delta = poolManager.modifyPosition(
            params.poolKey,
            IPoolManager.ModifyPositionParams(params.tickLower, params.tickUpper, int256(int128(liquidity))),
            params.hookData
        );
        if (
            uint256(int256(delta.amount0())) < params.amount0Min || uint256(int256(delta.amount1())) < params.amount1Min
        ) revert PriceSlippage();
    }

    function settleDeltas(address from, PoolKey memory poolKey, BalanceDelta delta) internal {
        if (delta.amount0() > 0) {
            pay(poolKey.currency0, from, address(poolManager), uint256(int256(delta.amount0())));
            poolManager.settle(poolKey.currency0);
        } else if (delta.amount0() < 0) {
            poolManager.take(poolKey.currency0, address(this), uint128(-delta.amount0()));
        }

        if (delta.amount1() > 0) {
            pay(poolKey.currency0, from, address(poolManager), uint256(int256(delta.amount1())));
            poolManager.settle(poolKey.currency1);
        } else if (delta.amount1() < 0) {
            poolManager.take(poolKey.currency1, address(this), uint128(-delta.amount1()));
        }
    }

    function lockAcquired(bytes calldata data) external override returns (bytes memory) {
        CallbackData memory callbackData = abi.decode(data, (CallbackData));
        if (callbackData.callbackType == CallbackType.AddLiquidity) {
            AddLiquidityParams memory params = abi.decode(callbackData.params, (AddLiquidityParams));
            (uint128 liquidity, BalanceDelta delta) = addLiquidityCallback(params);
            settleDeltas(callbackData.sender, params.poolKey, delta);
            return abi.encode(liquidity, delta.amount0(), delta.amount1());
        }

        // TODO: handle decrease liquidity here
        return abi.encode(0);
    }
}
