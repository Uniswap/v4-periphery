// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BalanceDelta, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import {LiquidityRange, LiquidityRangeId, LiquidityRangeIdLibrary} from "../types/LiquidityRange.sol";
import {SafeCallback} from "./SafeCallback.sol";
import {ImmutableState} from "./ImmutableState.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";

import {CurrencySettleTake} from "../libraries/CurrencySettleTake.sol";
import {FeeMath} from "../libraries/FeeMath.sol";
import {BaseLiquidityHandler} from "./BaseLiquidityHandler.sol";

// TODO: remove
import {console2} from "forge-std/console2.sol";

abstract contract BaseLiquidityManagement is BaseLiquidityHandler {
    using LiquidityRangeIdLibrary for LiquidityRange;
    using CurrencyLibrary for Currency;
    using CurrencySettleTake for Currency;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;

    constructor(IPoolManager _poolManager) BaseLiquidityHandler(_poolManager) {}

    function _increaseLiquidity(
        LiquidityRange memory range,
        uint256 liquidityToAdd,
        bytes calldata hookData,
        bool claims,
        address owner
    ) internal returns (BalanceDelta delta) {
        delta = abi.decode(
            poolManager.unlock(
                abi.encodeCall(this.handleIncreaseLiquidity, (msg.sender, range, liquidityToAdd, hookData, claims))
            ),
            (BalanceDelta)
        );
    }

    function _decreaseLiquidity(
        LiquidityRange memory range,
        uint256 liquidityToRemove,
        bytes calldata hookData,
        bool claims,
        address owner
    ) internal returns (BalanceDelta delta) {
        delta = abi.decode(
            poolManager.unlock(
                abi.encodeCall(this.handleDecreaseLiquidity, (owner, range, liquidityToRemove, hookData, claims))
            ),
            (BalanceDelta)
        );
    }

    function _collect(LiquidityRange memory range, bytes calldata hookData, bool claims, address owner)
        internal
        returns (BalanceDelta delta)
    {
        delta = abi.decode(
            poolManager.unlock(abi.encodeCall(this.handleCollect, (owner, range, hookData, claims))), (BalanceDelta)
        );
    }

    // --- View Functions --- //
    function feesOwed(address owner, LiquidityRange memory range)
        public
        view
        returns (uint256 token0Owed, uint256 token1Owed)
    {
        Position memory position = positions[owner][range.toId()];

        (uint256 feeGrowthInside0X128, uint256 feeGrowthInside1X128) =
            poolManager.getFeeGrowthInside(range.key.toId(), range.tickLower, range.tickUpper);

        (token0Owed, token1Owed) = FeeMath.getFeesOwed(
            feeGrowthInside0X128,
            feeGrowthInside1X128,
            position.feeGrowthInside0LastX128,
            position.feeGrowthInside1LastX128,
            position.liquidity
        );
        token0Owed += position.tokensOwed0;
        token1Owed += position.tokensOwed1;
    }
}
