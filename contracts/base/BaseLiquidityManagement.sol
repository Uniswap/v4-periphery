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

    enum LiquidityOperation {
        INCREASE,
        DECREASE,
        COLLECT
    }

    mapping(address owner => mapping(LiquidityRangeId rangeId => Position)) public positions;

    error UnlockFailure();

    constructor(IPoolManager _poolManager) ImmutableState(_poolManager) {}

    function zeroOut(BalanceDelta delta, Currency currency0, Currency currency1, address owner, bool claims) public {
        if (delta.amount0() < 0) currency0.settle(poolManager, owner, uint256(int256(-delta.amount0())), claims);
        else if (delta.amount0() > 0) currency0.send(poolManager, owner, uint128(delta.amount0()), claims);

        if (delta.amount1() < 0) currency1.settle(poolManager, owner, uint256(int256(-delta.amount1())), claims);
        else if (delta.amount1() > 0) currency1.send(poolManager, owner, uint128(delta.amount1()), claims);
    }

    function _unlockCallback(bytes calldata data) internal override returns (bytes memory) {
        (
            LiquidityOperation op,
            address owner,
            LiquidityRange memory range,
            uint256 liquidityChange,
            bytes memory hookData,
            bool claims
        ) = abi.decode(data, (LiquidityOperation, address, LiquidityRange, uint256, bytes, bool));

        if (op == LiquidityOperation.INCREASE) {
            return abi.encode(_increaseLiquidityAndZeroOut(owner, range, liquidityChange, hookData, claims));
        } else if (op == LiquidityOperation.DECREASE) {
            return abi.encode(_decreaseLiquidityAndZeroOut(owner, range, liquidityChange, hookData, claims));
        } else if (op == LiquidityOperation.COLLECT) {
            return abi.encode(_collectAndZeroOut(owner, range, 0, hookData, claims));
        } else {
            revert UnlockFailure();
        }
    }

    function _modifyLiquidity(address owner, LiquidityRange memory range, int256 liquidityChange, bytes memory hookData)
        internal
        returns (BalanceDelta liquidityDelta, BalanceDelta totalFeesAccrued)
    {
        (liquidityDelta, totalFeesAccrued) = poolManager.modifyLiquidity(
            range.key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: range.tickLower,
                tickUpper: range.tickUpper,
                liquidityDelta: liquidityChange,
                salt: range.key.hooks.getLiquiditySalt(owner)
            }),
            hookData
        );
    }

    function _increaseLiquidity(
        address owner,
        LiquidityRange memory range,
        uint256 liquidityToAdd,
        bytes memory hookData,
        bool claims
    ) internal returns (BalanceDelta) {
        // Note that the liquidityDelta includes totalFeesAccrued. The totalFeesAccrued is returned separately for accounting purposes.
        (BalanceDelta liquidityDelta, BalanceDelta totalFeesAccrued) =
            _modifyLiquidity(owner, range, liquidityToAdd.toInt256(), hookData);

        Position storage position = positions[owner][range.toId()];

        // Account for fees that were potentially collected to other users on the same range.
        (uint256 token0Owed, uint256 token1Owed) = _updateFeeGrowth(range, position);
        BalanceDelta callerFeesAccrued = toBalanceDelta(token0Owed.toInt128(), token1Owed.toInt128());
        BalanceDelta feesToCollect = totalFeesAccrued - callerFeesAccrued;
        range.key.currency0.take(poolManager, address(this), uint128(feesToCollect.amount0()), true);
        range.key.currency1.take(poolManager, address(this), uint128(feesToCollect.amount1()), true);

        {
        // the delta applied from the above actions is liquidityDelta - feesToCollect, note that the actual total delta for the caller may be different because actions can be chained
        BalanceDelta callerDelta = liquidityDelta - feesToCollect;

        // Update the tokensOwed0 and tokensOwed1 values for the caller.
        // if callerDelta <= 0, then tokensOwed0 and tokensOwed1 should be zero'd out as all fees were re-invested into a new position.
        // if callerDelta > 0, then even after re-investing old fees, the caller still has some fees to collect that were not added into the position so they are accounted.

        position.tokensOwed0 = callerDelta.amount0() > 0 ? position.tokensOwed0 += uint128(callerDelta.amount0()) : 0;
        position.tokensOwed1 = callerDelta.amount1() > 0 ? position.tokensOwed1 += uint128(callerDelta.amount1()) : 0;
        }
    }

    function _increaseLiquidityAndZeroOut(
        address owner,
        LiquidityRange memory range,
        uint256 liquidityToAdd,
        bytes memory hookData,
        bool claims
    ) internal returns (BalanceDelta delta) {
        delta = _increaseLiquidity(owner, range, liquidityToAdd, hookData, claims);
        zeroOut(delta, range.key.currency0, range.key.currency1, owner, claims);
    }

    function _increaseLiquidityWithLock(
        address owner,
        LiquidityRange memory range,
        uint256 liquidityToAdd,
        bytes memory hookData,
        bool claims
    ) internal returns (BalanceDelta) {
        return abi.decode(
            poolManager.unlock(abi.encode(LiquidityOperation.INCREASE, owner, range, liquidityToAdd, hookData, claims)),
            (BalanceDelta)
        );
    }

    function _decreaseLiquidity(
        address owner,
        LiquidityRange memory range,
        uint256 liquidityToRemove,
        bytes memory hookData,
        bool claims
    ) internal returns (BalanceDelta delta) {
        (BalanceDelta liquidityDelta, BalanceDelta totalFeesAccrued) =
            _modifyLiquidity(owner, range, -(liquidityToRemove.toInt256()), hookData);

        // take all tokens first
        // do NOT take tokens directly to the owner because this contract might be holding fees
        // that need to be paid out (position.tokensOwed)
        if (liquidityDelta.amount0() > 0) {
            range.key.currency0.take(poolManager, address(this), uint128(liquidityDelta.amount0()), true);
        }
        if (liquidityDelta.amount1() > 0) {
            range.key.currency1.take(poolManager, address(this), uint128(liquidityDelta.amount1()), true);
        }

        // when decreasing liquidity, the user collects: 1) principal liquidity, 2) new fees, 3) old fees (position.tokensOwed)

        Position storage position = positions[owner][range.toId()];
        (uint128 token0Owed, uint128 token1Owed) = _updateFeeGrowth(range, position);
        BalanceDelta principalDelta = liquidityDelta - totalFeesAccrued;

        // new fees += old fees + principal liquidity
        token0Owed += position.tokensOwed0 + uint128(principalDelta.amount0());
        token1Owed += position.tokensOwed1 + uint128(principalDelta.amount1());

        position.tokensOwed0 = 0;
        position.tokensOwed1 = 0;
        position.liquidity -= liquidityToRemove;

        delta = toBalanceDelta(int128(token0Owed), int128(token1Owed));

        return delta;
    }

    function _decreaseLiquidityAndZeroOut(
        address owner,
        LiquidityRange memory range,
        uint256 liquidityToRemove,
        bytes memory hookData,
        bool claims
    ) internal returns (BalanceDelta delta) {
        delta = _decreaseLiquidity(owner, range, liquidityToRemove, hookData, claims);
        zeroOut(delta, range.key.currency0, range.key.currency1, owner, claims);
    }

    function _decreaseLiquidityWithLock(
        address owner,
        LiquidityRange memory range,
        uint256 liquidityToRemove,
        bytes memory hookData,
        bool claims
    ) internal returns (BalanceDelta) {
        return abi.decode(
            poolManager.unlock(
                abi.encode(LiquidityOperation.DECREASE, owner, range, liquidityToRemove, hookData, claims)
            ),
            (BalanceDelta)
        );
    }

    function _collect(address owner, LiquidityRange memory range, bytes memory hookData, bool claims)
        internal
        returns (BalanceDelta)
    {
        (, BalanceDelta totalFeesAccrued) = _modifyLiquidity(owner, range, 0, hookData);

        PoolKey memory key = range.key;
        Position storage position = positions[owner][range.toId()];

        // take all fees first then distribute
        if (totalFeesAccrued.amount0() > 0) {
            key.currency0.take(poolManager, address(this), uint128(totalFeesAccrued.amount0()), true);
        }
        if (totalFeesAccrued.amount1() > 0) {
            key.currency1.take(poolManager, address(this), uint128(totalFeesAccrued.amount1()), true);
        }

        // collecting fees: new fees and old fees
        (uint128 token0Owed, uint128 token1Owed) = _updateFeeGrowth(range, position);
        token0Owed += position.tokensOwed0;
        token1Owed += position.tokensOwed1;

        position.tokensOwed0 = 0;
        position.tokensOwed1 = 0;

        return toBalanceDelta(uint256(token0Owed).toInt128(), uint256(token1Owed).toInt128());
    }

    function _collectAndZeroOut(address owner, LiquidityRange memory range, uint256, bytes memory hookData, bool claims)
        internal
        returns (BalanceDelta delta)
    {
        delta = _collect(owner, range, hookData, claims);
        zeroOut(delta, range.key.currency0, range.key.currency1, owner, claims);
    }

    function _collectWithLock(address owner, LiquidityRange memory range, bytes memory hookData, bool claims)
        internal
        returns (BalanceDelta)
    {
        return abi.decode(
            poolManager.unlock(abi.encode(LiquidityOperation.COLLECT, owner, range, 0, hookData, claims)),
            (BalanceDelta)
        );
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
