// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice Non-conforming PoolManager stand-in serving arbitrary storage values, used to prove that the lens
///         invariant checks turn inconsistent state (e.g. StateLibrary layout drift on a new chain) into loud
///         reverts instead of silently wrong TVL
contract MockSettableExtsloadManager {
    mapping(bytes32 => bytes32) internal slots;

    function set(bytes32 slot, bytes32 value) external {
        slots[slot] = value;
    }

    function extsload(bytes32 slot) external view returns (bytes32) {
        return slots[slot];
    }

    function extsload(bytes32[] calldata query) external view returns (bytes32[] memory values) {
        values = new bytes32[](query.length);
        for (uint256 i; i < query.length; i++) {
            values[i] = slots[query[i]];
        }
    }
}
