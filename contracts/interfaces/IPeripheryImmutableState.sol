// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

/// @title Immutable state
/// @notice Functions that return immutable state of the router
interface IPeripheryImmutableState {
    /// @return Returns the address of the Uniswap V4 PoolManager
    function poolManager() external view returns (address);

    /// @return Returns the address of WETH9
    function WETH9() external view returns (address);
}
