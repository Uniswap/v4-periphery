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
import {IBaseLiquidityManagement} from "../interfaces/IBaseLiquidityManagement.sol";

contract BaseLiquidityManagement is IBaseLiquidityManagement, SafeCallback {
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

    mapping(address owner => mapping(LiquidityRangeId rangeId => Position)) public positions;

    constructor(IPoolManager _manager) ImmutableState(_manager) {}

    function zeroOut(BalanceDelta delta, Currency currency0, Currency currency1, address owner, bool claims) public {
        if (delta.amount0() < 0) currency0.settle(manager, owner, uint256(int256(-delta.amount0())), claims);
        else if (delta.amount0() > 0) currency0.send(manager, owner, uint128(delta.amount0()), claims);

        if (delta.amount1() < 0) currency1.settle(manager, owner, uint256(int256(-delta.amount1())), claims);
        else if (delta.amount1() > 0) currency1.send(manager, owner, uint128(delta.amount1()), claims);
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
            return new bytes(0);
        }
    }

    function _modifyLiquidity(address owner, LiquidityRange memory range, int256 liquidityChange, bytes memory hookData)
        internal
        returns (BalanceDelta liquidityDelta, BalanceDelta totalFeesAccrued)
    {
        (liquidityDelta, totalFeesAccrued) = manager.modifyLiquidity(
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
        bytes memory hookData
    ) internal returns (BalanceDelta) {
        // Note that the liquidityDelta includes totalFeesAccrued. The totalFeesAccrued is returned separately for accounting purposes.
        (BalanceDelta liquidityDelta, BalanceDelta totalFeesAccrued) =
            _modifyLiquidity(owner, range, liquidityToAdd.toInt256(), hookData);

        Position storage position = positions[owner][range.toId()];

        // Account for fees that were potentially collected to other users on the same range.
        BalanceDelta callerFeesAccrued = _updateFeeGrowth(range, position);
        BalanceDelta feesToCollect = totalFeesAccrued - callerFeesAccrued;
        range.key.currency0.take(manager, address(this), uint128(feesToCollect.amount0()), true);
        range.key.currency1.take(manager, address(this), uint128(feesToCollect.amount1()), true);

        // the delta applied from the above actions is liquidityDelta - feesToCollect, note that the actual total delta for the caller may be different because actions can be chained
        BalanceDelta callerDelta = liquidityDelta - feesToCollect;

        // update liquidity after feeGrowth is updated
        position.liquidity += liquidityToAdd;

        // Update the tokensOwed0 and tokensOwed1 values for the caller.
        // if callerDelta < 0, existing fees were re-invested AND net new tokens are required for the liquidity increase
        // if callerDelta == 0, existing fees were reinvested (autocompounded)
        // if callerDelta > 0, some but not all existing fees were used to increase liquidity. Any remainder is added to the position's owed tokens
        if (callerDelta.amount0() > 0) {
            position.tokensOwed0 += uint128(callerDelta.amount0());
            range.key.currency0.take(manager, address(this), uint128(callerDelta.amount0()), true);
            callerDelta = toBalanceDelta(0, callerDelta.amount1());
        } else {
            position.tokensOwed0 = 0;
        }

        if (callerDelta.amount1() > 0) {
            position.tokensOwed1 += uint128(callerDelta.amount1());
            range.key.currency1.take(manager, address(this), uint128(callerDelta.amount1()), true);
            callerDelta = toBalanceDelta(callerDelta.amount0(), 0);
        } else {
            position.tokensOwed1 = 0;
        }

        return callerDelta;
    }

    function _increaseLiquidityAndZeroOut(
        address owner,
        LiquidityRange memory range,
        uint256 liquidityToAdd,
        bytes memory hookData,
        bool claims
    ) internal returns (BalanceDelta delta) {
        delta = _increaseLiquidity(owner, range, liquidityToAdd, hookData);
        zeroOut(delta, range.key.currency0, range.key.currency1, owner, claims);
    }

    function _lockAndIncreaseLiquidity(
        address owner,
        LiquidityRange memory range,
        uint256 liquidityToAdd,
        bytes memory hookData,
        bool claims
    ) internal returns (BalanceDelta) {
        return abi.decode(
            manager.unlock(abi.encode(LiquidityOperation.INCREASE, owner, range, liquidityToAdd, hookData, claims)),
            (BalanceDelta)
        );
    }

    function _decreaseLiquidity(
        address owner,
        LiquidityRange memory range,
        uint256 liquidityToRemove,
        bytes memory hookData
    ) internal returns (BalanceDelta delta) {
        (BalanceDelta liquidityDelta, BalanceDelta totalFeesAccrued) =
            _modifyLiquidity(owner, range, -(liquidityToRemove.toInt256()), hookData);

        // take all tokens first
        // do NOT take tokens directly to the owner because this contract might be holding fees
        // that need to be paid out (position.tokensOwed)
        if (liquidityDelta.amount0() > 0) {
            range.key.currency0.take(manager, address(this), uint128(liquidityDelta.amount0()), true);
        }
        if (liquidityDelta.amount1() > 0) {
            range.key.currency1.take(manager, address(this), uint128(liquidityDelta.amount1()), true);
        }

        // when decreasing liquidity, the user collects: 1) principal liquidity, 2) new fees, 3) old fees (position.tokensOwed)

        Position storage position = positions[owner][range.toId()];
        BalanceDelta callerFeesAccrued = _updateFeeGrowth(range, position);
        BalanceDelta principalDelta = liquidityDelta - totalFeesAccrued;

        // new fees = new fees + old fees + principal liquidity
        callerFeesAccrued = callerFeesAccrued
            + toBalanceDelta(uint256(position.tokensOwed0).toInt128(), uint256(position.tokensOwed1).toInt128())
            + principalDelta;

        position.tokensOwed0 = 0;
        position.tokensOwed1 = 0;
        position.liquidity -= liquidityToRemove;

        return callerFeesAccrued;
    }

    function _decreaseLiquidityAndZeroOut(
        address owner,
        LiquidityRange memory range,
        uint256 liquidityToRemove,
        bytes memory hookData,
        bool claims
    ) internal returns (BalanceDelta delta) {
        delta = _decreaseLiquidity(owner, range, liquidityToRemove, hookData);
        zeroOut(delta, range.key.currency0, range.key.currency1, owner, claims);
    }

    function _lockAndDecreaseLiquidity(
        address owner,
        LiquidityRange memory range,
        uint256 liquidityToRemove,
        bytes memory hookData,
        bool claims
    ) internal returns (BalanceDelta) {
        return abi.decode(
            manager.unlock(abi.encode(LiquidityOperation.DECREASE, owner, range, liquidityToRemove, hookData, claims)),
            (BalanceDelta)
        );
    }

    function _collect(address owner, LiquidityRange memory range, bytes memory hookData)
        internal
        returns (BalanceDelta)
    {
        (, BalanceDelta totalFeesAccrued) = _modifyLiquidity(owner, range, 0, hookData);

        PoolKey memory key = range.key;
        Position storage position = positions[owner][range.toId()];

        // take all fees first then distribute
        if (totalFeesAccrued.amount0() > 0) {
            key.currency0.take(manager, address(this), uint128(totalFeesAccrued.amount0()), true);
        }
        if (totalFeesAccrued.amount1() > 0) {
            key.currency1.take(manager, address(this), uint128(totalFeesAccrued.amount1()), true);
        }

        // collecting fees: new fees and old fees
        BalanceDelta callerFeesAccrued = _updateFeeGrowth(range, position);
        callerFeesAccrued = callerFeesAccrued
            + toBalanceDelta(uint256(position.tokensOwed0).toInt128(), uint256(position.tokensOwed1).toInt128());

        position.tokensOwed0 = 0;
        position.tokensOwed1 = 0;

        return callerFeesAccrued;
    }

    function _collectAndZeroOut(address owner, LiquidityRange memory range, uint256, bytes memory hookData, bool claims)
        internal
        returns (BalanceDelta delta)
    {
        delta = _collect(owner, range, hookData);
        zeroOut(delta, range.key.currency0, range.key.currency1, owner, claims);
    }

    function _lockAndCollect(address owner, LiquidityRange memory range, bytes memory hookData, bool claims)
        internal
        returns (BalanceDelta)
    {
        return abi.decode(
            manager.unlock(abi.encode(LiquidityOperation.COLLECT, owner, range, 0, hookData, claims)), (BalanceDelta)
        );
    }

    function _updateFeeGrowth(LiquidityRange memory range, Position storage position)
        internal
        returns (BalanceDelta _feesOwed)
    {
        (uint256 feeGrowthInside0X128, uint256 feeGrowthInside1X128) =
            manager.getFeeGrowthInside(range.key.toId(), range.tickLower, range.tickUpper);

        (uint128 token0Owed, uint128 token1Owed) = FeeMath.getFeesOwed(
            feeGrowthInside0X128,
            feeGrowthInside1X128,
            position.feeGrowthInside0LastX128,
            position.feeGrowthInside1LastX128,
            position.liquidity
        );
        _feesOwed = toBalanceDelta(uint256(token0Owed).toInt128(), uint256(token1Owed).toInt128());

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
            manager.getFeeGrowthInside(range.key.toId(), range.tickLower, range.tickUpper);

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
