// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @title ISpoke
/// @notice Minimal vendored surface of the Aave v4 Spoke used by the lending adapter and its fork
///         test: the supply/withdraw/borrow/repay entry points, collateral enablement, the batching
///         multicall, and the position/reserve reads. Pinned to the deployed mainnet Spoke ABI.
/// @dev    Aave v4 is hub-and-spoke. A market is keyed by a per-Spoke `reserveId` (not an asset
///         address); the Spoke is the contract the account calls. Behaviors that differ from Aave v3
///         and matter to the adapter:
///         - `supply`/`withdraw`/`borrow`/`repay` all take `onBehalfOf`; the caller must be
///           `onBehalfOf` or an authorized position manager for it. A MarginAccount acts as its own
///           `onBehalfOf` AND is the caller, so no position-manager registration is needed.
///         - `borrow` and `withdraw` deliver the underlying to `msg.sender` (the account); there is no
///           receiver argument.
///         - `supply` does NOT auto-enable collateral; `setUsingAsCollateral` must be called for the
///           supplied reserve to back a borrow.
///         - debt is the sum of drawn debt and accrued premium; `getUserTotalDebt` returns both.
///         - `multicall` is a delegatecall-to-self batch, so `msg.sender` is preserved into each call
///           (the supply path relies on this to pull the underlying against the account's allowance).
interface ISpoke {
    /// @notice Reserve-level data. Field order and types match the deployed Spoke for ABI decoding.
    /// @param underlying The address of the underlying asset.
    /// @param hub The address of the associated Hub.
    /// @param assetId The identifier of the asset in the Hub.
    /// @param decimals The number of decimals of the underlying asset.
    /// @param collateralRisk The risk associated with a collateral asset, in basis points.
    /// @param flags The packed boolean flags of the reserve (a wrapped uint8).
    /// @param dynamicConfigKey The key of the reserve's latest dynamic config.
    struct Reserve {
        address underlying;
        address hub;
        uint16 assetId;
        uint8 decimals;
        uint24 collateralRisk;
        uint8 flags;
        uint32 dynamicConfigKey;
    }

    /// @notice Reserve configuration. Subset of the reserve state used to gate actions.
    /// @param collateralRisk The risk associated with a collateral asset, in basis points.
    /// @param paused True if all actions are prevented for the reserve.
    /// @param frozen True if new activity is prevented for the reserve.
    /// @param borrowable True if the reserve is borrowable.
    /// @param receiveSharesEnabled True if a liquidator can receive collateral shares.
    struct ReserveConfig {
        uint24 collateralRisk;
        bool paused;
        bool frozen;
        bool borrowable;
        bool receiveSharesEnabled;
    }

    /// @notice Dynamic reserve configuration data.
    /// @param collateralFactor The proportion of a reserve's value usable as collateral, in basis
    ///        points (1e4 == 100%). The closest analog of Aave v3's liquidation threshold.
    /// @param maxLiquidationBonus The maximum extra collateral given to a liquidator, in basis points.
    /// @param liquidationFee The protocol fee on liquidations, in basis points.
    struct DynamicReserveConfig {
        uint16 collateralFactor;
        uint32 maxLiquidationBonus;
        uint16 liquidationFee;
    }

    /// @notice Account-level position and health data, scoped to this Spoke.
    /// @dev "Value" units are USD scaled by the oracle decimals (1e8 on mainnet).
    /// @param riskPremium The risk premium of the position, in basis points.
    /// @param avgCollateralFactor The collateral-value-weighted collateral factor, in WAD.
    /// @param healthFactor The position health factor, in WAD (1e18 == 1.0; below 1e18 is liquidatable).
    /// @param totalCollateralValue The total collateral value, in Value units (USD * 1e8).
    /// @param totalDebtValueRay The total debt value, in Value units (USD * 1e8) scaled by RAY (1e27).
    /// @param activeCollateralCount The number of active collateral reserves.
    /// @param borrowCount The number of borrowed reserves.
    struct UserAccountData {
        uint256 riskPremium;
        uint256 avgCollateralFactor;
        uint256 healthFactor;
        uint256 totalCollateralValue;
        uint256 totalDebtValueRay;
        uint256 activeCollateralCount;
        uint256 borrowCount;
    }

    /// @notice Supplies `amount` of the reserve's underlying, crediting supply shares to `onBehalfOf`.
    /// @dev The Spoke pulls the underlying from the caller, so prior approval is required. Does NOT
    ///      enable the reserve as collateral; call `setUsingAsCollateral` for that.
    /// @param reserveId The reserve identifier.
    /// @param amount The amount of underlying to supply.
    /// @param onBehalfOf The owner of the position credited.
    /// @return suppliedShares The amount of supply shares minted.
    /// @return suppliedAmount The amount of underlying supplied.
    function supply(uint256 reserveId, uint256 amount, address onBehalfOf)
        external
        returns (uint256 suppliedShares, uint256 suppliedAmount);

    /// @notice Withdraws underlying from the reserve, burning `onBehalfOf`'s supply shares and sending
    ///         the underlying to the caller (`msg.sender`).
    /// @dev An amount greater than the maximum withdrawable signals a full withdrawal.
    /// @param reserveId The reserve identifier.
    /// @param amount The amount of underlying to withdraw.
    /// @param onBehalfOf The owner of the position debited.
    /// @return withdrawnShares The amount of supply shares burned.
    /// @return withdrawnAmount The amount of underlying withdrawn.
    function withdraw(uint256 reserveId, uint256 amount, address onBehalfOf)
        external
        returns (uint256 withdrawnShares, uint256 withdrawnAmount);

    /// @notice Borrows underlying from the reserve against `onBehalfOf`'s collateral, delivering the
    ///         underlying to the caller (`msg.sender`).
    /// @param reserveId The reserve identifier.
    /// @param amount The amount of underlying to borrow.
    /// @param onBehalfOf The owner of the position the debt is generated against.
    /// @return drawnShares The amount of debt shares minted.
    /// @return drawnAmount The amount of underlying borrowed.
    function borrow(uint256 reserveId, uint256 amount, address onBehalfOf)
        external
        returns (uint256 drawnShares, uint256 drawnAmount);

    /// @notice Repays underlying debt owed by `onBehalfOf`. The Spoke pulls the underlying from the
    ///         caller, so prior approval is required.
    /// @dev An amount greater than the total debt is capped to the total debt (drawn plus premium), so
    ///      `type(uint256).max` repays in full. This cap applies on the Spoke directly; the
    ///      GiverPositionManager forbids max-uint, but the adapter calls the Spoke directly.
    /// @param reserveId The reserve identifier.
    /// @param amount The amount of underlying to repay.
    /// @param onBehalfOf The owner of the position whose debt is repaid.
    /// @return restoredShares The amount of drawn shares burned.
    /// @return totalAmountRepaid The amount of underlying repaid (drawn plus premium).
    function repay(uint256 reserveId, uint256 amount, address onBehalfOf)
        external
        returns (uint256 restoredShares, uint256 totalAmountRepaid);

    /// @notice Enables or disables a supplied reserve as collateral for `onBehalfOf`.
    /// @dev Idempotent: returns early if the reserve is already in the requested state.
    /// @param reserveId The reserve identifier.
    /// @param usingAsCollateral True to use the supply as collateral.
    /// @param onBehalfOf The owner of the position being modified.
    function setUsingAsCollateral(uint256 reserveId, bool usingAsCollateral, address onBehalfOf) external;

    /// @notice Executes a batch of calls against the Spoke via delegatecall-to-self, preserving
    ///         `msg.sender` into each call.
    /// @param data The encoded calls to execute in order.
    /// @return results The raw bytes returned by each call.
    function multicall(bytes[] calldata data) external returns (bytes[] memory results);

    /// @notice Returns the amount of underlying supplied by `user` in the reserve.
    /// @param reserveId The reserve identifier.
    /// @param user The address of the user.
    /// @return The amount of underlying supplied by the user.
    function getUserSuppliedAssets(uint256 reserveId, address user) external view returns (uint256);

    /// @notice Returns the total debt of `user` in the reserve (drawn plus accrued premium).
    /// @param reserveId The reserve identifier.
    /// @param user The address of the user.
    /// @return The total debt amount.
    function getUserTotalDebt(uint256 reserveId, address user) external view returns (uint256);

    /// @notice Returns the account-level position and health data for `user`, scoped to this Spoke.
    /// @param user The address of the user.
    /// @return The user account data struct.
    function getUserAccountData(address user) external view returns (UserAccountData memory);

    /// @notice Returns the reserve struct for a given reserve identifier.
    /// @param reserveId The reserve identifier.
    /// @return The reserve struct.
    function getReserve(uint256 reserveId) external view returns (Reserve memory);

    /// @notice Returns the reserve configuration for a given reserve identifier.
    /// @param reserveId The reserve identifier.
    /// @return The reserve configuration struct.
    function getReserveConfig(uint256 reserveId) external view returns (ReserveConfig memory);

    /// @notice Returns the dynamic reserve configuration at a given key.
    /// @param reserveId The reserve identifier.
    /// @param dynamicConfigKey The key of the dynamic config to read.
    /// @return The dynamic reserve configuration struct.
    function getDynamicReserveConfig(uint256 reserveId, uint32 dynamicConfigKey)
        external
        view
        returns (DynamicReserveConfig memory);

    /// @notice Returns the address of the AaveOracle contract pricing this Spoke's reserves.
    /// @return The oracle address.
    function ORACLE() external view returns (address);
}
