// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @title IAaveOracle
/// @notice Minimal vendored surface of the Aave v3 price oracle. Returns asset prices in the
///         protocol's base currency (USD on mainnet, 8 decimals).
interface IAaveOracle {
    /// @notice Returns the price of an asset in the protocol's base currency.
    /// @param asset The address of the underlying asset.
    /// @return The asset price in the base currency (USD on mainnet, 8 decimals).
    function getAssetPrice(address asset) external view returns (uint256);
}
