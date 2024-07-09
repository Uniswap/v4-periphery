// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {BalanceDelta, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {CurrencySettleTake} from "../libraries/CurrencySettleTake.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";

import "forge-std/console2.sol";

/// @title a library to store callers' currency deltas in transient storage
/// @dev this library implements the equivalent of a mapping, as transient storage can only be accessed in assembly
library TransientLiquidityDelta {
    using CurrencySettleTake for Currency;
    using TransientStateLibrary for IPoolManager;

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
        addDelta(currency0, holder, delta.amount0());
        addDelta(currency1, holder, delta.amount1());
    }

    function addDelta(Currency currency, address caller, int128 delta) internal {
        bytes32 hashSlot = _computeSlot(caller, currency);
        assembly {
            let oldValue := tload(hashSlot)
            let newValue := add(oldValue, delta)
            tstore(hashSlot, newValue)
        }
    }

    function subtractDelta(Currency currency, address caller, int128 delta) internal {
        bytes32 hashSlot = _computeSlot(caller, currency);
        assembly {
            let oldValue := tload(hashSlot)
            let newValue := sub(oldValue, delta)
            tstore(hashSlot, newValue)
        }
    }

    function close(Currency currency, IPoolManager manager, address holder, bool claims)
        internal
        returns (int128 delta)
    {
        // getDelta(currency, holder);
        bytes32 hashSlot = _computeSlot(holder, currency);
        assembly {
            delta := tload(hashSlot)
        }

        if (delta < 0) {
            currency.settle(manager, holder, uint256(-int256(delta)), claims);
        } else {
            currency.take(manager, holder, uint256(int256(delta)), claims);
        }

        // setDelta(0);
        assembly {
            tstore(hashSlot, 0)
        }
    }

    function closeDelta(IPoolManager manager, address holder, Currency currency0, Currency currency1, bool claims)
        internal
    {
        close(currency0, manager, holder, claims);
        close(currency1, manager, holder, claims);
    }

    function getBalanceDelta(address holder, Currency currency0, Currency currency1)
        internal
        view
        returns (BalanceDelta delta)
    {
        delta = toBalanceDelta(getDelta(currency0, holder), getDelta(currency1, holder));
    }

    /// Copied from v4-core/src/libraries/CurrencyDelta.sol:
    /// @notice sets a new currency delta for a given caller and currency
    function setDelta(Currency currency, address caller, int128 delta) internal {
        bytes32 hashSlot = _computeSlot(caller, currency);

        assembly {
            tstore(hashSlot, delta)
        }
    }

    /// @notice gets a new currency delta for a given caller and currency
    // TODO: is returning 128 bits safe?
    function getDelta(Currency currency, address caller) internal view returns (int128 delta) {
        bytes32 hashSlot = _computeSlot(caller, currency);

        assembly {
            delta := tload(hashSlot)
        }
    }
}
