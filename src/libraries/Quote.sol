// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

/// @notice This is a temporary library that allows us to use transient storage (tstore/tload)
/// for the quote.
/// TODO: This library can be deleted when we have the transient keyword support in solidity.
library Quote {
    // The slot holding the quote. bytes32(uint256(keccak256("Quote")) - 1)
    bytes32 internal constant QUOTE_SLOT = 0xbbd426867243227198e50d68cdb6f9a2a3a1c5ef433a2b6e7fcf3f462364310a;

    function read() internal view returns (int256 quote) {
        assembly ("memory-safe") {
            quote := tload(QUOTE_SLOT)
        }
    }

    function set(int256 quote) internal {
        assembly ("memory-safe") {
            tstore(QUOTE_SLOT, quote)
        }
    }

    function reset() internal {
        assembly ("memory-safe") {
            tstore(QUOTE_SLOT, 0)
        }
    }
}
