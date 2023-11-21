// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

/// @title Function for getting the current chain ID
library ChainId {
    /// @dev Gets the current chain ID
    /// @return chainId The current chain ID
    function get() internal view returns (uint256 chainId) {
        assembly {
            chainId := chainid()
        }
    }
}
