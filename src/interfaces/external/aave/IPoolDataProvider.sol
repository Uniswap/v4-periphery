// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @title IPoolDataProvider
/// @notice Minimal vendored surface of the Aave v3 AaveProtocolDataProvider used by the lending
///         adapter to resolve reserve token addresses and reserve configuration without decoding the
///         version-sensitive packed reserve data on the Pool.
interface IPoolDataProvider {
    /// @notice Returns the addresses of the receipt tokens for a reserve.
    /// @param asset The address of the underlying reserve asset.
    /// @return aTokenAddress The aToken (supply receipt) address.
    /// @return stableDebtTokenAddress The stable debt token address.
    /// @return variableDebtTokenAddress The variable debt token address.
    function getReserveTokensAddresses(address asset)
        external
        view
        returns (address aTokenAddress, address stableDebtTokenAddress, address variableDebtTokenAddress);

    /// @notice Returns the configuration data for a reserve.
    /// @param asset The address of the underlying reserve asset.
    /// @return decimals The asset decimals.
    /// @return ltv The maximum loan-to-value (basis points).
    /// @return liquidationThreshold The liquidation threshold (basis points).
    /// @return liquidationBonus The liquidation bonus (basis points).
    /// @return reserveFactor The reserve factor (basis points).
    /// @return usageAsCollateralEnabled Whether the asset can be used as collateral.
    /// @return borrowingEnabled Whether borrowing the asset is enabled.
    /// @return stableBorrowRateEnabled Whether stable-rate borrowing is enabled.
    /// @return isActive Whether the reserve is active.
    /// @return isFrozen Whether the reserve is frozen.
    function getReserveConfigurationData(address asset)
        external
        view
        returns (
            uint256 decimals,
            uint256 ltv,
            uint256 liquidationThreshold,
            uint256 liquidationBonus,
            uint256 reserveFactor,
            bool usageAsCollateralEnabled,
            bool borrowingEnabled,
            bool stableBorrowRateEnabled,
            bool isActive,
            bool isFrozen
        );
}
