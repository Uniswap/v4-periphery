// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice Non-conforming PoolManager stand-in whose batched extsload returns fewer words than requested,
///         e.g. a wrong address or divergent proxy on a new chain
contract MockShortExtsloadManager {
    /// @dev Single-slot reads report an initialized pool (sqrtPriceX96 = 2^96, tick 0) so the scan proceeds
    function extsload(bytes32) external pure returns (bytes32) {
        return bytes32(uint256(1) << 96);
    }

    function extsload(bytes32[] calldata) external pure returns (bytes32[] memory) {
        return new bytes32[](0);
    }
}
