// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @title IComet
/// @notice Minimal vendored surface of a Compound v3 (Comet) instance used by the lending adapter and
///         its fork test: the supply/withdraw entry points and the collateral/base reads. Pinned to
///         the deployed mainnet Comet ABI.
/// @dev    A Comet instance is single-base: it has exactly one borrowable `baseToken` and a set of
///         collateral assets. There is no separate borrow/repay: borrowing the base is `withdraw`ing
///         it (drawing the base balance negative), and repaying is `supply`ing it. Behaviors that
///         matter to the adapter:
///         - `supply`/`withdraw` operate on `msg.sender`'s own account; a MarginAccount acts as
///           itself, so no operator authorization is needed. `withdrawTo` sends to an explicit
///           recipient (still debiting `msg.sender`).
///         - Supplying the base repays the borrow first, then any excess becomes a base supply
///           (positive balance). There is NO share-based "repay all" and no `type(uint256).max`
///           sentinel; a full repay supplies the accrued borrow, and supplying more than the borrow
///           leaves the excess as a base supply rather than reverting.
///         - `borrowBalanceOf` is denominated in the base token and is re-accrued to `block.timestamp`
///           in the view: it recomputes the borrow index from the elapsed time since the last protocol
///           interaction, so it reflects the current obligation, not a stale stored figure.
///         - `getPrice` returns a USD price scaled to Comet's price scale (1e8) for any registered
///           price feed; collateral factors are WAD (1e18).
interface IComet {
    /// @notice Per-collateral-asset configuration. Field order/types match the deployed Comet.
    /// @param offset The asset's index in the account's collateral bitmap.
    /// @param asset The collateral asset address.
    /// @param priceFeed The price feed for the asset (fed to `getPrice`).
    /// @param scale `10 ** assetDecimals` for the collateral asset.
    /// @param borrowCollateralFactor The max LTV at which a borrow may be opened against this
    ///        collateral (WAD, 1e18 == 100%).
    /// @param liquidateCollateralFactor The LTV at which a position becomes liquidatable (WAD).
    /// @param liquidationFactor The fraction of collateral value credited on liquidation (WAD).
    /// @param supplyCap The maximum total this collateral the market accepts, in asset units.
    struct AssetInfo {
        uint8 offset;
        address asset;
        address priceFeed;
        uint64 scale;
        uint64 borrowCollateralFactor;
        uint64 liquidateCollateralFactor;
        uint64 liquidationFactor;
        uint128 supplyCap;
    }

    /// @notice Supply `amount` of `asset` from `msg.sender` to `msg.sender`. For a collateral asset
    ///         this posts collateral; for the base token it repays the borrow (then supplies excess).
    function supply(address asset, uint256 amount) external;

    /// @notice Withdraw `amount` of `asset` from `msg.sender` to `msg.sender`. For a collateral asset
    ///         this removes collateral; for the base token it draws a borrow.
    function withdraw(address asset, uint256 amount) external;

    /// @notice Withdraw `amount` of `asset` from `msg.sender`, delivering it to `to`.
    function withdrawTo(address to, address asset, uint256 amount) external;

    /// @notice The single borrowable base token of this Comet.
    function baseToken() external view returns (address);

    /// @notice The price feed for the base token (fed to `getPrice`).
    function baseTokenPriceFeed() external view returns (address);

    /// @notice `10 ** baseTokenDecimals`.
    function baseScale() external view returns (uint256);

    /// @notice USD price for `priceFeed`, scaled to Comet's price scale (1e8).
    function getPrice(address priceFeed) external view returns (uint256);

    /// @notice Configuration for a registered collateral `asset`. Reverts if `asset` is not a
    ///         collateral asset of this Comet.
    function getAssetInfoByAddress(address asset) external view returns (AssetInfo memory);

    /// @notice The account's supplied balance of collateral `asset`, in the asset's native decimals.
    function collateralBalanceOf(address account, address asset) external view returns (uint128);

    /// @notice The account's outstanding base-token borrow (0 if the account has a base supply),
    ///         re-accrued to `block.timestamp` in the view: it recomputes the borrow index from the
    ///         time elapsed since the last protocol interaction, so the returned value is the current
    ///         obligation rather than a stale stored figure.
    function borrowBalanceOf(address account) external view returns (uint256);
}
