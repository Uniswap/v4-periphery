// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @title IAaveOracle (v4)
/// @notice Minimal vendored surface of the Aave v4 oracle. Unlike Aave v3, the v4 oracle is keyed by
///         per-Spoke `reserveId`, not by asset address: there is no `getAssetPrice(address)`. Used by
///         the fork test to price the v4 reserves; the adapter itself does not read the oracle (it
///         derives LTV from the Spoke's account data).
interface IAaveOracle {
    /// @notice Returns the prices of the given reserves in the oracle base currency.
    /// @param reserveIds The reserve identifiers to price.
    /// @return The prices, in the oracle base currency (USD; see `decimals`).
    function getReservesPrices(uint256[] calldata reserveIds) external view returns (uint256[] memory);

    /// @notice Returns the price of a single reserve in the oracle base currency.
    /// @param reserveId The reserve identifier to price.
    /// @return The price, in the oracle base currency (USD; see `decimals`).
    function getReservePrice(uint256 reserveId) external view returns (uint256);

    /// @notice The number of decimals of the oracle base currency (8 on mainnet, i.e. 1e8 == $1).
    /// @return The base currency decimals.
    function decimals() external view returns (uint8);
}
