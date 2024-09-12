// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

/// @notice This is a temporary library that allows us to use transient storage (tstore/tload)
/// TODO: This library can be deleted when we have the transient keyword support in solidity.
library CacheAmountSpecified {
    // bytes32(uint256(keccak256("AmountSpecified")) - 1)
    bytes32 internal constant AMOUNT_SPECIFIED_SLOT = 0x040affe16a79096ebfed488ed052568637be7285d797c191b3a85e60cf8292f3;

    function set(uint256 amountSpecified) internal {
        assembly ("memory-safe") {
            tstore(AMOUNT_SPECIFIED_SLOT, amountSpecified)
        }
    }

    function get() internal view returns (uint256 amountSpecified) {
        assembly ("memory-safe") {
            amountSpecified := tload(AMOUNT_SPECIFIED_SLOT)
        }
    }
}
