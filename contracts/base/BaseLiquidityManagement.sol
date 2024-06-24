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
import {PositionLibrary} from "../libraries/Position.sol";

import "forge-std/console2.sol";

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
    using PositionLibrary for IBaseLiquidityManagement.Position;

    mapping(address owner => mapping(LiquidityRangeId rangeId => Position)) public positions;

    constructor(IPoolManager _manager) ImmutableState(_manager) {}

    function _closeCallerDeltas(
        BalanceDelta callerDeltas,
        Currency currency0,
        Currency currency1,
        address owner,
        bool claims
    ) internal {
        int128 callerDelta0 = callerDeltas.amount0();
        int128 callerDelta1 = callerDeltas.amount1();
        // On liquidity increase, the deltas should never be > 0.
        //  We always 0 out a caller positive delta because it is instead accounted for in position.tokensOwed.

        if (callerDelta0 < 0) currency0.settle(manager, owner, uint256(int256(-callerDelta0)), claims);
        else if (callerDelta0 > 0) currency0.send(manager, owner, uint128(callerDelta0), claims);

        if (callerDelta1 < 0) currency1.settle(manager, owner, uint256(int256(-callerDelta1)), claims);
        else if (callerDelta1 > 0) currency1.send(manager, owner, uint128(callerDelta1), claims);
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
            range.poolKey,
            IPoolManager.ModifyLiquidityParams({
                tickLower: range.tickLower,
                tickUpper: range.tickUpper,
                liquidityDelta: liquidityChange,
                salt: range.poolKey.hooks.getLiquiditySalt(owner)
            }),
            hookData
        );
    }

    /// @dev The delta returned from this call must be settled by the caller.
    /// Zeroing out the full balance of open deltas accounted to this address is unsafe until the callerDeltas are handled.
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

        // Calculate the portion of the liquidityDelta that is attributable to the caller.
        // We must account for fees that might be owed to other users on the same range.
        (uint256 feeGrowthInside0X128, uint256 feeGrowthInside1X128) =
            manager.getFeeGrowthInside(range.poolKey.toId(), range.tickLower, range.tickUpper);

        BalanceDelta callerFeesAccrued = FeeMath.getFeesOwed(
            feeGrowthInside0X128,
            feeGrowthInside1X128,
            position.feeGrowthInside0LastX128,
            position.feeGrowthInside1LastX128,
            position.liquidity
        );

        // Calculate the accurate tokens owed to the caller.
        // If the totalFeesAccrued equals the callerFeesAccrued then the total owed to the caller is just the liquidityDelta.
        // If the totalFeesAccrued is greater than the callerFeesAccrued, we must account for the difference.
        (int128 callerDelta0, int128 callerDelta1) = totalFeesAccrued != callerFeesAccrued
            ? _calculateCallerDeltas(liquidityDelta, totalFeesAccrued, callerFeesAccrued)
            : (liquidityDelta.amount0(), liquidityDelta.amount1());

        // Update position storage, sanitizing the tokensOwed and callerDelta values first.
        // if callerDelta > 0, then even after re-investing old fees, the caller still has some amount to collect that were not added into the position so they are accounted.
        // if callerDelta <= 0, then tokensOwed0 and tokensOwed1 should be zero'd out as all fees were re-invested into a new position.
        uint128 tokensOwed0 = 0;
        uint128 tokensOwed1 = 0;
        (tokensOwed0, callerDelta0) = callerDelta0 > 0 ? (uint128(callerDelta0), int128(0)) : (uint128(0), callerDelta0);
        (tokensOwed1, callerDelta1) = callerDelta1 > 0 ? (uint128(callerDelta1), int128(0)) : (uint128(0), callerDelta1);

        position.updateTokensOwed(tokensOwed0, tokensOwed1);
        position.addLiquidity(liquidityToAdd);
        position.updateFeeGrowthInside(feeGrowthInside0X128, feeGrowthInside1X128);

        return toBalanceDelta(callerDelta0, callerDelta1);
    }

    // Returns the new sanitized delta for the caller.
    function _calculateCallerDeltas(
        BalanceDelta liquidityDelta,
        BalanceDelta totalFeesAccrued,
        BalanceDelta callerFeesAccrued
    ) private pure returns (int128 callerDelta0, int128 callerDelta1) {
        (int128 liquidityDelta0, int128 liquidityDelta1) = (liquidityDelta.amount0(), liquidityDelta.amount1());
        (int128 totalFeesAccrued0, int128 totalFeesAccrued1) = (totalFeesAccrued.amount0(), totalFeesAccrued.amount1());
        (int128 callerFeesAccrued0, int128 callerFeesAccrued1) =
            (callerFeesAccrued.amount0(), callerFeesAccrued.amount1());

        callerDelta0 = totalFeesAccrued0 > callerFeesAccrued0
            ? _calculateCallerDelta(liquidityDelta.amount0(), totalFeesAccrued0, callerFeesAccrued0)
            : liquidityDelta0;

        callerDelta1 = totalFeesAccrued1 > callerFeesAccrued1
            ? _calculateCallerDelta(liquidityDelta.amount1(), totalFeesAccrued1, callerFeesAccrued1)
            : liquidityDelta1;
    }

    function _calculateCallerDelta(int128 liquidityDelta, int128 totalFeesAccrued, int128 callerFeesAccrued)
        private
        pure
        returns (int128 callerDelta)
    {
        unchecked {
            int128 feesAccruedOutsideCaller = totalFeesAccrued - callerFeesAccrued;
            callerDelta = liquidityDelta - feesAccruedOutsideCaller;
        }
    }

    function _increaseLiquidityAndZeroOut(
        address owner,
        LiquidityRange memory range,
        uint256 liquidityToAdd,
        bytes memory hookData,
        bool claims
    ) internal returns (BalanceDelta callerDelta) {
        callerDelta = _increaseLiquidity(owner, range, liquidityToAdd, hookData);
        _closeCallerDeltas(callerDelta, range.poolKey.currency0, range.poolKey.currency1, owner, claims);
        _closeAllDeltas(range.poolKey.currency0, range.poolKey.currency1);
    }

    // When chaining many actions, this should be called at the very end to close out any open deltas owed to or by this contract for other users on the same range.
    // This is safe because any amounts the caller should not pay or take have already been accounted for in closeCallerDeltas.
    function _closeAllDeltas(Currency currency0, Currency currency1) internal {
        (BalanceDelta delta) = manager.currencyDeltas(address(this), currency0, currency1);
        int128 delta0 = delta.amount0();
        int128 delta1 = delta.amount1();

        // Mint a receipt for the tokens owed to this address.
        if (delta0 > 0) currency0.take(manager, address(this), uint128(delta0), true);
        if (delta1 > 0) currency1.take(manager, address(this), uint128(delta1), true);
        // Burn the receipt for tokens owed to this address.
        if (delta0 < 0) currency0.settle(manager, address(this), uint256(int256(-delta0)), true);
        if (delta1 < 0) currency1.settle(manager, address(this), uint256(int256(-delta1)), true);
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
            range.poolKey.currency0.take(manager, address(this), uint128(liquidityDelta.amount0()), true);
        }
        if (liquidityDelta.amount1() > 0) {
            range.poolKey.currency1.take(manager, address(this), uint128(liquidityDelta.amount1()), true);
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
        _closeCallerDeltas(delta, range.poolKey.currency0, range.poolKey.currency1, owner, claims);
        _closeAllDeltas(range.poolKey.currency0, range.poolKey.currency1);
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

        PoolKey memory key = range.poolKey;
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
        _closeCallerDeltas(delta, range.poolKey.currency0, range.poolKey.currency1, owner, claims);
        _closeAllDeltas(range.poolKey.currency0, range.poolKey.currency1);
    }

    function _lockAndCollect(address owner, LiquidityRange memory range, bytes memory hookData, bool claims)
        internal
        returns (BalanceDelta)
    {
        return abi.decode(
            manager.unlock(abi.encode(LiquidityOperation.COLLECT, owner, range, 0, hookData, claims)), (BalanceDelta)
        );
    }

    // TODO: I deprecated this bc I liked to see the accounting in line in the top level function... and I like to do all the position updates at once.
    //  can keep but should at at least use the position library in here.
    function _updateFeeGrowth(LiquidityRange memory range, Position storage position)
        internal
        returns (BalanceDelta _feesOwed)
    {
        (uint256 feeGrowthInside0X128, uint256 feeGrowthInside1X128) =
            manager.getFeeGrowthInside(range.poolKey.toId(), range.tickLower, range.tickUpper);

        _feesOwed = FeeMath.getFeesOwed(
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
            manager.getFeeGrowthInside(range.poolKey.toId(), range.tickLower, range.tickUpper);

        (token0Owed) = FeeMath.getFeeOwed(feeGrowthInside0X128, position.feeGrowthInside0LastX128, position.liquidity);
        (token1Owed) = FeeMath.getFeeOwed(feeGrowthInside1X128, position.feeGrowthInside1LastX128, position.liquidity);
        token0Owed += position.tokensOwed0;
        token1Owed += position.tokensOwed1;
    }
}
