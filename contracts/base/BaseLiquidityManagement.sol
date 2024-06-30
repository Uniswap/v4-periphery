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
import {CurrencyDeltas} from "../libraries/CurrencyDeltas.sol";

import {FeeMath} from "../libraries/FeeMath.sol";
import {LiquiditySaltLibrary} from "../libraries/LiquiditySaltLibrary.sol";
import {IBaseLiquidityManagement} from "../interfaces/IBaseLiquidityManagement.sol";
import {PositionLibrary} from "../libraries/Position.sol";
import {BalanceDeltaExtensionLibrary} from "../libraries/BalanceDeltaExtensionLibrary.sol";
import {LiquidityDeltaAccounting} from "../libraries/LiquidityDeltaAccounting.sol";
import {TransientLiquidityDelta} from "../libraries/TransientLiquidityDelta.sol";

import "forge-std/console2.sol";

abstract contract BaseLiquidityManagement is IBaseLiquidityManagement, SafeCallback {
    using LiquidityRangeIdLibrary for LiquidityRange;
    using CurrencyLibrary for Currency;
    using CurrencySettleTake for Currency;
    using CurrencyDeltas for IPoolManager;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;
    using SafeCast for uint256;
    using LiquiditySaltLibrary for IHooks;
    using PositionLibrary for IBaseLiquidityManagement.Position;
    using BalanceDeltaExtensionLibrary for BalanceDelta;
    using LiquidityDeltaAccounting for BalanceDelta;
    using TransientLiquidityDelta for BalanceDelta;
    using TransientLiquidityDelta for Currency;
    using TransientLiquidityDelta for address;

    mapping(address owner => mapping(LiquidityRangeId rangeId => Position)) public positions;

    constructor(IPoolManager _manager) ImmutableState(_manager) {}

    function _msgSenderInternal() internal virtual returns (address);

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
        else if (callerDelta0 > 0) currency0.take(manager, owner, uint128(callerDelta0), claims);

        if (callerDelta1 < 0) currency1.settle(manager, owner, uint256(int256(-callerDelta1)), claims);
        else if (callerDelta1 > 0) currency1.take(manager, owner, uint128(callerDelta1), claims);

        owner.close(currency0, currency1);
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
    ) internal {
        // Note that the liquidityDelta includes totalFeesAccrued. The totalFeesAccrued is returned separately for accounting purposes.
        (BalanceDelta liquidityDelta, BalanceDelta totalFeesAccrued) =
            _modifyLiquidity(owner, range, liquidityToAdd.toInt256(), hookData);

        Position storage position = positions[owner][range.toId()];

        // Calculates the fee growth since the last time the positions feeGrowthInside was updated.
        // Also updates the feeGrowthInsideLast variables in storage.
        (BalanceDelta callerFeesAccrued) = _updateFeeGrowth(range, position);

        // Calculate the portion of the liquidityDelta that is attributable to the caller.
        // We must account for fees that might be owed to other users on the same range.
        (BalanceDelta callerDelta, BalanceDelta thisDelta) = liquidityDelta.split(callerFeesAccrued, totalFeesAccrued);

        // Update position storage, flushing the callerDelta value to tokensOwed first if necessary.
        // If callerDelta > 0, then even after investing callerFeesAccrued, the caller still has some amount to collect that were not added into the position so they are accounted to tokensOwed and removed from the final callerDelta returned.
        BalanceDelta tokensOwed;
        if (callerDelta.amount0() > 0) {
            (tokensOwed, callerDelta, thisDelta) =
                _moveCallerDeltaToTokensOwed(true, tokensOwed, callerDelta, thisDelta);
        }

        if (callerDelta.amount1() > 0) {
            (tokensOwed, callerDelta, thisDelta) =
                _moveCallerDeltaToTokensOwed(false, tokensOwed, callerDelta, thisDelta);
        }

        // Accrue all deltas to the caller.
        callerDelta.flush(_msgSenderInternal(), range.poolKey.currency0, range.poolKey.currency1);
        thisDelta.flush(address(this), range.poolKey.currency0, range.poolKey.currency1);

        position.addTokensOwed(tokensOwed);
        position.addLiquidity(liquidityToAdd);
    }

    // When chaining many actions, this should be called at the very end to close out any open deltas owed to or by this contract for other users on the same range.
    // This is safe because any amounts the caller should not pay or take have already been accounted for in closeCallerDeltas.
    function _closeThisDeltas(BalanceDelta delta, Currency currency0, Currency currency1) internal {
        int128 delta0 = delta.amount0();
        int128 delta1 = delta.amount1();

        // Mint a receipt for the tokens owed to this address.
        if (delta0 > 0) currency0.take(manager, address(this), uint128(delta0), true);
        if (delta1 > 0) currency1.take(manager, address(this), uint128(delta1), true);
        // Burn the receipt for tokens owed to this address.
        if (delta0 < 0) currency0.settle(manager, address(this), uint256(int256(-delta0)), true);
        if (delta1 < 0) currency1.settle(manager, address(this), uint256(int256(-delta1)), true);

        address(this).close(currency0, currency1);
    }

    function _moveCallerDeltaToTokensOwed(
        bool useAmount0,
        BalanceDelta tokensOwed,
        BalanceDelta callerDelta,
        BalanceDelta thisDelta
    ) private returns (BalanceDelta, BalanceDelta, BalanceDelta) {
        // credit the excess tokens to the position's tokensOwed
        tokensOwed =
            useAmount0 ? tokensOwed.setAmount0(callerDelta.amount0()) : tokensOwed.setAmount1(callerDelta.amount1());

        // this contract is responsible for custodying the excess tokens
        thisDelta =
            useAmount0 ? thisDelta.addAmount0(callerDelta.amount0()) : thisDelta.addAmount1(callerDelta.amount1());

        // the caller is not expected to collect the excess tokens
        callerDelta = useAmount0 ? callerDelta.setAmount0(0) : callerDelta.setAmount1(0);

        return (tokensOwed, callerDelta, thisDelta);
    }

    /// Any outstanding amounts owed to the caller from the underlying modify call must be collected explicitly with `collect`.
    function _decreaseLiquidity(
        address owner,
        LiquidityRange memory range,
        uint256 liquidityToRemove,
        bytes memory hookData
    ) internal {
        (BalanceDelta liquidityDelta, BalanceDelta totalFeesAccrued) =
            _modifyLiquidity(owner, range, -(liquidityToRemove.toInt256()), hookData);

        Position storage position = positions[owner][range.toId()];

        // Calculates the fee growth since the last time the positions feeGrowthInside was updated
        // Also updates the position's the feeGrowthInsideLast variables in storage.
        (BalanceDelta callerFeesAccrued) = _updateFeeGrowth(range, position);

        // Account for fees accrued to other users on the same range.
        (BalanceDelta callerDelta, BalanceDelta thisDelta) = liquidityDelta.split(callerFeesAccrued, totalFeesAccrued);

        BalanceDelta tokensOwed;

        // Flush the callerDelta, incrementing the tokensOwed to the user and the amount claimable to this contract.
        if (callerDelta.amount0() > 0) {
            (tokensOwed, callerDelta, thisDelta) =
                _moveCallerDeltaToTokensOwed(true, tokensOwed, callerDelta, thisDelta);
        }

        if (callerDelta.amount1() > 0) {
            (tokensOwed, callerDelta, thisDelta) =
                _moveCallerDeltaToTokensOwed(false, tokensOwed, callerDelta, thisDelta);
        }
        callerDelta.flush(owner, range.poolKey.currency0, range.poolKey.currency1);
        thisDelta.flush(address(this), range.poolKey.currency0, range.poolKey.currency1);

        position.addTokensOwed(tokensOwed);
        position.subtractLiquidity(liquidityToRemove);
    }

    // The recipient may not be the original owner.
    function _collect(address owner, LiquidityRange memory range, bytes memory hookData) internal {
        BalanceDelta callerDelta;
        BalanceDelta thisDelta;
        Position storage position = positions[owner][range.toId()];

        // Only call modify if there is still liquidty in this position.
        if (position.liquidity != 0) {
            // Do not add or decrease liquidity, just trigger fee updates.
            (BalanceDelta liquidityDelta, BalanceDelta totalFeesAccrued) = _modifyLiquidity(owner, range, 0, hookData);

            // Also updates the position's the feeGrowthInsideLast variables in storage.
            (BalanceDelta callerFeesAccrued) = _updateFeeGrowth(range, position);

            // Account for fees accrued to other users on the same range.
            // TODO: Opt when liquidityDelta == 0
            (callerDelta, thisDelta) = liquidityDelta.split(callerFeesAccrued, totalFeesAccrued);
        }

        // Allow the caller to collect the tokens owed.
        // Tokens owed that the caller collects is paid for by this contract.
        // ie. Transfer the tokensOwed amounts to the caller from the position manager through the pool manager.
        // TODO case where this contract does not have enough credits to pay the caller?
        BalanceDelta tokensOwed =
            toBalanceDelta(uint256(position.tokensOwed0).toInt128(), uint256(position.tokensOwed1).toInt128());
        callerDelta = callerDelta + tokensOwed;
        thisDelta = thisDelta - tokensOwed;

        callerDelta.flush(owner, range.poolKey.currency0, range.poolKey.currency1);
        thisDelta.flush(address(this), range.poolKey.currency0, range.poolKey.currency1);

        position.clearTokensOwed();
    }

    function _validateBurn(address owner, LiquidityRange memory range) internal {
        LiquidityRangeId rangeId = range.toId();
        Position storage position = positions[owner][rangeId];
        if (position.liquidity > 0) revert PositionMustBeEmpty();
        if (position.tokensOwed0 != 0 && position.tokensOwed1 != 0) revert TokensMustBeCollected();
        delete positions[owner][rangeId];
    }

    function _updateFeeGrowth(LiquidityRange memory range, Position storage position)
        internal
        returns (BalanceDelta callerFeesAccrued)
    {
        (uint256 feeGrowthInside0X128, uint256 feeGrowthInside1X128) =
            manager.getFeeGrowthInside(range.poolKey.toId(), range.tickLower, range.tickUpper);

        callerFeesAccrued = FeeMath.getFeesOwed(
            feeGrowthInside0X128,
            feeGrowthInside1X128,
            position.feeGrowthInside0LastX128,
            position.feeGrowthInside1LastX128,
            position.liquidity
        );

        position.updateFeeGrowthInside(feeGrowthInside0X128, feeGrowthInside1X128);
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
