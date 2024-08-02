// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";

/// @title Currency Deltas
/// @notice Fetch two currency deltas in a single call
library CurrencyDeltas {
    using SafeCast for int256;

    /// @notice Get the current delta for a caller in the two given currencies
    /// @param _caller The address of the caller
    /// @param currency0 The currency to lookup the delta
    /// @param currency1 The other currency to lookup the delta
    /// @return BalanceDelta The delta of the two currencies packed
    /// amount0 corresponding to currency0 and amount1 corresponding to currency1
    function currencyDeltas(IPoolManager manager, address _caller, Currency currency0, Currency currency1)
        internal
        view
        returns (BalanceDelta)
    {
        bytes32 tloadSlot0;
        bytes32 tloadSlot1;
        assembly {
            mstore(0, _caller)
            mstore(32, currency0)
            tloadSlot0 := keccak256(0, 64)

            mstore(0, _caller)
            mstore(32, currency1)
            tloadSlot1 := keccak256(0, 64)
        }

        return toBalanceDelta(
            int256(uint256(manager.exttload(tloadSlot0))).toInt128(),
            int256(uint256(manager.exttload(tloadSlot1))).toInt128()
        );
    }
}
