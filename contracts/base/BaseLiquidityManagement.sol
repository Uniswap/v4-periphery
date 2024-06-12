// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
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
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";

import {CurrencySettleTake} from "../libraries/CurrencySettleTake.sol";
import {CurrencySenderLibrary} from "../libraries/CurrencySenderLibrary.sol";
import {CurrencyDeltas} from "../libraries/CurrencyDeltas.sol";

import {FeeMath} from "../libraries/FeeMath.sol";
import {LiquiditySaltLibrary} from "../libraries/LiquiditySaltLibrary.sol";

contract BaseLiquidityManagement is SafeCallback {
    using LiquidityRangeIdLibrary for LiquidityRange;
    using CurrencyLibrary for Currency;
    using CurrencySettleTake for Currency;
    using CurrencySenderLibrary for Currency;
    using CurrencyDeltas for IPoolManager;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;
    using SafeCast for uint256;
    using LiquiditySaltLibrary for IHooks;

    // details about the liquidity position
    struct Position {
        // the nonce for permits
        uint96 nonce;
        // the address that is approved for spending this token
        address operator;
        uint256 liquidity;
        // the fee growth of the aggregate position as of the last action on the individual position
        uint256 feeGrowthInside0LastX128;
        uint256 feeGrowthInside1LastX128;
        // how many uncollected tokens are owed to the position, as of the last computation
        uint128 tokensOwed0;
        uint128 tokensOwed1;
    }

    mapping(address owner => mapping(LiquidityRangeId rangeId => Position)) public positions;

    error LockFailure();

    constructor(IPoolManager _poolManager) ImmutableState(_poolManager) {}

    function modifyLiquidity(LiquidityRange memory range, int256 liquidityDelta, bytes calldata hookData, bool claims)
        internal
        returns (BalanceDelta delta)
    {
        delta = abi.decode(
            poolManager.unlock(
                abi.encodeCall(this.handleModifyLiquidity, (msg.sender, range, liquidityDelta, hookData, claims))
            ),
            (BalanceDelta)
        );
    }

    function _unlockCallback(bytes calldata data) internal override returns (bytes memory) {
        (bool success, bytes memory returnData) = address(this).call(data);
        if (success) return returnData;
        if (returnData.length == 0) revert LockFailure();
        // if the call failed, bubble up the reason
        /// @solidity memory-safe-assembly
        assembly {
            revert(add(returnData, 32), mload(returnData))
        }
    }

    function handleModifyLiquidity(
        address sender,
        LiquidityRange calldata range,
        int256 liquidityDelta,
        bytes calldata hookData,
        bool claims
    ) external returns (BalanceDelta delta) {
        (BalanceDelta _delta, BalanceDelta _feesAccrued) = poolManager.modifyLiquidity(
            range.key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: range.tickLower,
                tickUpper: range.tickUpper,
                liquidityDelta: liquidityDelta,
                salt: range.key.hooks.getLiquiditySalt(sender)
            }),
            hookData
        );

        if (liquidityDelta > 0) {
            delta = _settleIncreaseLiquidity(_delta, _feesAccrued, sender, range, uint256(liquidityDelta), claims);
        } else if (liquidityDelta < 0) {
            delta = _settleDecreaseLiquidity(_delta, _feesAccrued, sender, range, uint256(-liquidityDelta), claims);
        } else {
            delta = _settleCollect(_feesAccrued, sender, range, claims);
        }
    }

    function _settleIncreaseLiquidity(
        BalanceDelta delta,
        BalanceDelta feesAccrued,
        address sender,
        LiquidityRange calldata range,
        uint256 liquidityToAdd,
        bool claims
    ) internal returns (BalanceDelta) {
        Position storage position = positions[sender][range.toId()];

        // take fees not accrued by user's position
        (uint256 token0Owed, uint256 token1Owed) = _updateFeeGrowth(range, position);
        BalanceDelta excessFees = feesAccrued - toBalanceDelta(token0Owed.toInt128(), token1Owed.toInt128());
        range.key.currency0.take(poolManager, address(this), uint128(excessFees.amount0()), true);
        range.key.currency1.take(poolManager, address(this), uint128(excessFees.amount1()), true);

        // get remaining deltas: the user pays additional to increase liquidity OR the user collects their fees
        delta = poolManager.currencyDeltas(address(this), range.key.currency0, range.key.currency1);

        // TODO: use position.tokensOwed0 to pay the delta?
        if (delta.amount0() < 0) {
            range.key.currency0.settle(poolManager, sender, uint256(int256(-delta.amount0())), claims);
        }
        if (delta.amount1() < 0) {
            range.key.currency1.settle(poolManager, sender, uint256(int256(-delta.amount1())), claims);
        }
        if (delta.amount0() > 0) {
            range.key.currency0.take(poolManager, address(this), uint256(int256(delta.amount0())), true);
        }
        if (delta.amount1() > 0) {
            range.key.currency1.take(poolManager, address(this), uint256(int256(delta.amount1())), true);
        }

        positions[sender][range.toId()].liquidity += liquidityToAdd;

        // collected fees are credited to the position OR zero'd out
        delta.amount0() > 0 ? position.tokensOwed0 += uint128(delta.amount0()) : position.tokensOwed0 = 0;
        delta.amount1() > 0 ? position.tokensOwed1 += uint128(delta.amount1()) : position.tokensOwed1 = 0;

        return delta;
    }

    function _settleDecreaseLiquidity(
        BalanceDelta delta,
        BalanceDelta feesAccrued,
        address owner,
        LiquidityRange calldata range,
        uint256 liquidityToRemove,
        bool claims
    ) internal returns (BalanceDelta) {
        // take all tokens first
        // do NOT take tokens directly to the owner because this contract might be holding fees
        // that need to be paid out (position.tokensOwed)
        if (delta.amount0() > 0) {
            range.key.currency0.take(poolManager, address(this), uint128(delta.amount0()), true);
        }
        if (delta.amount1() > 0) {
            range.key.currency1.take(poolManager, address(this), uint128(delta.amount1()), true);
        }

        // when decreasing liquidity, the user collects: 1) principal liquidity, 2) new fees, 3) old fees (position.tokensOwed)

        Position storage position = positions[owner][range.toId()];
        (uint128 token0Owed, uint128 token1Owed) = _updateFeeGrowth(range, position);
        BalanceDelta principalDelta = delta - feesAccrued;

        // new fees += old fees + principal liquidity
        token0Owed += position.tokensOwed0 + uint128(principalDelta.amount0());
        token1Owed += position.tokensOwed1 + uint128(principalDelta.amount1());

        position.tokensOwed0 = 0;
        position.tokensOwed1 = 0;
        position.liquidity -= liquidityToRemove;

        delta = toBalanceDelta(int128(token0Owed), int128(token1Owed));

        // sending tokens to the owner
        if (token0Owed > 0) range.key.currency0.send(poolManager, owner, token0Owed, claims);
        if (token1Owed > 0) range.key.currency1.send(poolManager, owner, token1Owed, claims);

        return delta;
    }

    function _settleCollect(BalanceDelta feesAccrued, address owner, LiquidityRange calldata range, bool takeClaims)
        internal
        returns (BalanceDelta)
    {
        PoolKey memory key = range.key;
        Position storage position = positions[owner][range.toId()];

        // take all fees first then distribute
        if (feesAccrued.amount0() > 0) {
            key.currency0.take(poolManager, address(this), uint128(feesAccrued.amount0()), true);
        }
        if (feesAccrued.amount1() > 0) {
            key.currency1.take(poolManager, address(this), uint128(feesAccrued.amount1()), true);
        }

        // collecting fees: new fees and old fees
        (uint128 token0Owed, uint128 token1Owed) = _updateFeeGrowth(range, position);
        token0Owed += position.tokensOwed0;
        token1Owed += position.tokensOwed1;

        if (token0Owed > 0) key.currency0.send(poolManager, owner, token0Owed, takeClaims);
        if (token1Owed > 0) key.currency1.send(poolManager, owner, token1Owed, takeClaims);

        position.tokensOwed0 = 0;
        position.tokensOwed1 = 0;

        return toBalanceDelta(uint256(token0Owed).toInt128(), uint256(token1Owed).toInt128());
    }

    function _updateFeeGrowth(LiquidityRange memory range, Position storage position)
        internal
        returns (uint128 token0Owed, uint128 token1Owed)
    {
        (uint256 feeGrowthInside0X128, uint256 feeGrowthInside1X128) =
            poolManager.getFeeGrowthInside(range.key.toId(), range.tickLower, range.tickUpper);

        (token0Owed, token1Owed) = FeeMath.getFeesOwed(
            feeGrowthInside0X128,
            feeGrowthInside1X128,
            position.feeGrowthInside0LastX128,
            position.feeGrowthInside1LastX128,
            position.liquidity
        );

        position.feeGrowthInside0LastX128 = feeGrowthInside0X128;
        position.feeGrowthInside1LastX128 = feeGrowthInside1X128;
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
