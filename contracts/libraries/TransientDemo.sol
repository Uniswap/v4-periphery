// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

/// @title a library to store callers' currency deltas in transient storage
/// @dev this library implements the equivalent of a mapping, as transient storage can only be accessed in assembly
library TransientLiquidityDelta {
    /// @notice calculates which storage slot a delta should be stored in for a given caller and currency
    function _computeSlot(address caller_, Currency currency) internal pure returns (bytes32 hashSlot) {
        assembly {
            mstore(0, caller_)
            mstore(32, currency)
            hashSlot := keccak256(0, 64)
        }
    }

    /// @notice Flush a BalanceDelta into transient storage for a given holder
    function flush(BalanceDelta delta, address holder, Currency currency0, Currency currency1) internal {
        setDelta(currency0, holder, delta.amount0());
        setDelta(currency1, holder, delta.amount1());
    }

    function addDelta(Currency currency, address caller, int128 delta) internal {
        bytes32 hashSlot = _computeSlot(caller, currency);
        assembly {
            let oldValue := tload(hashSlot)
            let newValue := add(oldValue, delta)
            tstore(hashSlot, newValue)
        }
    }

    function subDelta(Currency currency, address caller, int128 delta) internal {
        bytes32 hashSlot = _computeSlot(caller, currency);
        assembly {
            let oldValue := tload(hashSlot)
            let newValue := sub(oldValue, delta)
            tstore(hashSlot, newValue)
        }
    }

    /// @notice sets a new currency delta for a given caller and currency
    function setDelta(Currency currency, address caller, int256 delta) internal {
        bytes32 hashSlot = _computeSlot(caller, currency);

        assembly {
            tstore(hashSlot, delta)
        }
    }

    /// @notice gets a new currency delta for a given caller and currency
    function getDelta(Currency currency, address caller) internal view returns (int256 delta) {
        bytes32 hashSlot = _computeSlot(caller, currency);

        assembly {
            delta := tload(hashSlot)
        }
    }
}
