// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @title IPoolAddressesProvider
/// @notice Minimal vendored surface of the Aave v3 PoolAddressesProvider. Resolves the stable proxy
///         addresses of the Pool and the protocol data provider for a given market.
interface IPoolAddressesProvider {
    /// @notice Returns the address of the Pool proxy.
    /// @return The Pool proxy address.
    function getPool() external view returns (address);

    /// @notice Returns the address of the protocol data provider.
    /// @return The protocol data provider address.
    function getPoolDataProvider() external view returns (address);
}
