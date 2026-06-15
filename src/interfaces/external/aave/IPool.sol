// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @title IPool
/// @notice Minimal vendored surface of the Aave v3 Pool used by the lending adapter: supply,
///         withdraw, borrow, repay, and the account-level health read. Pinned to the deployed
///         mainnet Pool ABI.
interface IPool {
    /// @notice Supplies `amount` of `asset` into the protocol, minting aTokens to `onBehalfOf`.
    /// @param asset The address of the underlying asset to supply.
    /// @param amount The amount to supply.
    /// @param onBehalfOf The address that will receive the aTokens.
    /// @param referralCode The referral code (unused; pass 0).
    function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;

    /// @notice Withdraws `amount` of `asset`, burning the caller's aTokens and sending the underlying
    ///         to `to`.
    /// @param asset The address of the underlying asset to withdraw.
    /// @param amount The amount to withdraw, or `type(uint256).max` to withdraw the full aToken
    ///        balance.
    /// @param to The address that will receive the underlying asset.
    /// @return The final amount withdrawn.
    function withdraw(address asset, uint256 amount, address to) external returns (uint256);

    /// @notice Borrows `amount` of `asset`, sending the underlying to `msg.sender` and accruing debt
    ///         to `onBehalfOf`.
    /// @param asset The address of the underlying asset to borrow.
    /// @param amount The amount to borrow.
    /// @param interestRateMode The interest rate mode (1 = stable, 2 = variable).
    /// @param referralCode The referral code (unused; pass 0).
    /// @param onBehalfOf The address that will incur the debt.
    function borrow(address asset, uint256 amount, uint256 interestRateMode, uint16 referralCode, address onBehalfOf)
        external;

    /// @notice Repays `amount` of `asset` debt owed by `onBehalfOf`.
    /// @param asset The address of the underlying asset to repay.
    /// @param amount The amount to repay, or `type(uint256).max` to repay the full debt of the given
    ///        rate mode.
    /// @param interestRateMode The interest rate mode of the debt being repaid (1 = stable,
    ///        2 = variable).
    /// @param onBehalfOf The address whose debt is repaid.
    /// @return The final amount repaid.
    function repay(address asset, uint256 amount, uint256 interestRateMode, address onBehalfOf)
        external
        returns (uint256);

    /// @notice Returns the account-level position data for `user` in the protocol's base currency
    ///         (USD-denominated, 8 decimals on mainnet).
    /// @param user The address to query.
    /// @return totalCollateralBase The total collateral value in the base currency.
    /// @return totalDebtBase The total debt value in the base currency.
    /// @return availableBorrowsBase The borrowing power left in the base currency.
    /// @return currentLiquidationThreshold The weighted-average liquidation threshold (basis points).
    /// @return ltv The weighted-average loan-to-value (basis points).
    /// @return healthFactor The current health factor (WAD; below 1e18 is liquidatable).
    function getUserAccountData(address user)
        external
        view
        returns (
            uint256 totalCollateralBase,
            uint256 totalDebtBase,
            uint256 availableBorrowsBase,
            uint256 currentLiquidationThreshold,
            uint256 ltv,
            uint256 healthFactor
        );
}
