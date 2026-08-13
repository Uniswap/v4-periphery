// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Math} from "openzeppelin-contracts/contracts/utils/math/Math.sol";

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {ILendingAdapter} from "./interfaces/ILendingAdapter.sol";
import {IComet} from "./interfaces/external/compound-v3/IComet.sol";
import {OwnableAdapter} from "./base/OwnableAdapter.sol";
import {PositionAmountResolver} from "./base/PositionAmountResolver.sol";
import {Market} from "./types/Market.sol";
import {MarketAllowlist, MarketNotSupported} from "./types/MarketAllowlist.sol";
import {Ltv, toLtv} from "./types/Ltv.sol";
import {PositionData} from "./types/PositionData.sol";

/// @title CompoundV3LendingAdapter
/// @author Uniswap Labs
/// @notice A singleton `ILendingAdapter` over one Compound v3 (Comet) instance. The adapter is a thin
///         shell composing a governed `(collateral, debt)` allowlist and an owner guard; all encode
///         and read logic delegates to the Comet, so no Compound math is reimplemented. Each encoded
///         call is executed by a `MarginAccount` as itself, so the Comet acts on the account's own
///         balances and no delegated authorization is needed. The motivating use case is a long
///         position in a Comet collateral asset (e.g. supply UNI, borrow the base USDC).
/// @dev    Design and trust notes:
///         - A Comet is single-base: it has exactly one borrowable `baseToken` and a set of
///           collateral assets. This adapter binds one Comet at construction, so every routed market
///           MUST have `debt == comet.baseToken()` and a `collateral` that is a registered Comet
///           collateral asset; `setMarket` validates both. To serve a different base, deploy another
///           adapter against that Comet.
///         - Comet has no separate borrow/repay: borrowing the base is `withdraw`ing it (drawing the
///           base balance negative) and repaying is `supply`ing it. The encoders map the four
///           `ILendingAdapter` primitives onto `supply`/`withdraw`/`withdrawTo` accordingly.
///         - The adapter only encodes calls; it never holds funds or moves tokens. The executing
///           `MarginAccount` performs a regular call (never a delegatecall) and validates the `to` it
///           is handed, but it does not decode this calldata, so THIS ADAPTER is what guarantees the
///           target is `lendingProtocol()`, the value is zero, the Comet acts on the account's own
///           balances, and a withdrawal's recipient is the passed `receiver`.
///         - Comet's `withdraw`/`withdrawTo` operate on the caller's own account, so `account` must be
///           the caller for withdraw-collateral (asserted via `AccountMismatch`); the `MarginAccount`
///           always passes its own address.
///         - Borrowing capacity is enforced by Comet at call time against the collateral's BORROW
///           collateral factor; `maxLtvWad` returns the LIQUIDATE collateral factor (the liquidation
///           boundary, the analog of Morpho's `lltv` / Aave's liquidation threshold), so a borrow may
///           open below `maxLtvWad` yet be rejected by Comet if it exceeds the tighter borrow factor.
///         - Reads are per-position within the Comet: `collateralBalanceOf` is the specific
///           collateral, `borrowBalanceOf` is the account's base borrow accrued to `block.timestamp`.
///           They are account-level in the base only when the account holds multiple positions in the
///           same Comet (multiple collaterals backing one base borrow), so use a distinct `subId` per
///           Comet position, as with the Aave adapters.
///         - Routing is curated: every `encode*` and read reverts `MarketNotSupported` for a pair the
///           owner has not allowlisted, never a silent default market.
/// @custom:security-contact security@uniswap.org
contract CompoundV3LendingAdapter is ILendingAdapter, OwnableAdapter, PositionAmountResolver {
    // WAD scale for loan-to-value ratios and collateral factors (Comet expresses factors in WAD).
    uint256 private constant WAD = 1e18;

    /// @notice The Comet instance this adapter routes to. The single call target for every market;
    ///         all `encode*` functions return this address as `target`.
    IComet public immutable comet;

    /// @notice The Comet's single borrowable base token, cached at construction. Every routed market's
    ///         `debt` must equal this.
    address public immutable baseToken;

    /// @notice `10 ** baseTokenDecimals` for the Comet's base token, cached at construction. Immutable
    ///         per Comet instance, so it is read once here rather than on every valuation.
    uint256 public immutable baseScale;

    /// @notice The governed allowlist of routable `(collateral, debt)` pairs. Managed via `setMarket`;
    ///         the owner guard lives in `OwnableAdapter`.
    MarketAllowlist internal _markets;

    /// @dev Thrown when the Comet reports a zero base token at construction.
    error ZeroAddress();

    /// @dev Thrown when `setMarket` is asked to enable a pair whose `debt` is not this Comet's base
    ///      token. A Comet can only borrow its single base asset.
    /// @param debt The debt token supplied.
    /// @param baseToken The Comet's actual base token.
    error DebtNotBaseToken(Currency debt, address baseToken);

    /// @dev Thrown when `encodeWithdrawCollateral` is called with an `account` that is not the caller.
    ///      Comet's withdraw debits the caller's own balances, so the encoder only ever produces a
    ///      withdrawal for the account that calls it (the `MarginAccount` always passes its own
    ///      address).
    /// @param account The account argument supplied to the encoder.
    /// @param caller The actual caller (`msg.sender`).
    error AccountMismatch(address account, address caller);

    /// @notice Emitted when a market is enabled or disabled in the allowlist.
    /// @param collateral The collateral token address of the market.
    /// @param debt The debt token address of the market (this Comet's base token).
    /// @param allowed Whether the pair is now routable.
    event MarketSet(address indexed collateral, address indexed debt, bool allowed);

    /// @param comet_ The Comet instance this adapter routes to.
    /// @param owner_ The initial adapter owner (governance).
    constructor(IComet comet_, address owner_) OwnableAdapter(owner_) {
        address base = comet_.baseToken();
        if (base == address(0)) revert ZeroAddress();
        comet = comet_;
        baseToken = base;
        baseScale = comet_.baseScale();
    }

    /// @inheritdoc ILendingAdapter
    function lendingProtocol() external view returns (address) {
        return address(comet);
    }

    /// @notice The Comet's base-token USD price feed, read fresh from the Comet on each call. Unlike
    ///         the base token and its scale (fixed per Comet), the price feed is governance-mutable
    ///         behind the same Comet proxy, so caching it could value debt with a superseded feed;
    ///         since `debtValue` feeds the health/LTV reads, it is resolved live (audit L-14).
    /// @return The Comet's current base-token price feed.
    function baseTokenPriceFeed() public view returns (address) {
        return comet.baseTokenPriceFeed();
    }

    /// @inheritdoc ILendingAdapter
    function isSupportedMarket(Market calldata market) external view returns (bool) {
        return _markets.isAllowed(market);
    }

    /// @inheritdoc ILendingAdapter
    /// @dev Encodes `IComet.supply(collateral, amount)`. Comet supplies from and credits
    ///      `msg.sender` (the account), so the collateral is posted on behalf of the account. The
    ///      `value` field is always 0 (Comet is non-payable).
    function encodeSupplyCollateral(address account, Market calldata market, uint256 amount)
        external
        view
        returns (address, uint256, bytes memory)
    {
        _requireSupportedMarket(market);
        account; // the account is Comet's msg.sender; supply credits it, no onBehalf argument exists
        return (address(comet), 0, abi.encodeCall(IComet.supply, (Currency.unwrap(market.collateral), amount)));
    }

    /// @inheritdoc ILendingAdapter
    /// @dev No-op: Comet counts a supplied collateral asset as collateral automatically, so there is
    ///      no separate enable step. Returns empty `callData`, which the account skips.
    function encodeEnableCollateral(address, Market calldata) external pure returns (address, uint256, bytes memory) {
        return (address(0), 0, "");
    }

    /// @inheritdoc ILendingAdapter
    /// @dev Encodes `IComet.withdrawTo(receiver, collateral, amount)`, which debits the account's
    ///      collateral and delivers it to `receiver` directly, so the account forwards nothing. The
    ///      `receiver` is validated by `MarginAccount` before executing. Comet's withdraw acts on the
    ///      caller's own balances, so `account` must be the caller.
    function encodeWithdrawCollateral(address account, Market calldata market, uint256 amount, address receiver)
        external
        view
        returns (address, uint256, bytes memory)
    {
        _requireSupportedMarket(market);
        if (account != msg.sender) revert AccountMismatch(account, msg.sender);
        return
            (
                address(comet),
                0,
                abi.encodeCall(IComet.withdrawTo, (receiver, Currency.unwrap(market.collateral), amount))
            );
    }

    /// @inheritdoc ILendingAdapter
    /// @dev Encodes `IComet.withdraw(baseToken, amount)`: withdrawing the base with no base supply
    ///      draws a borrow, delivered to `msg.sender` (the account), which forwards it to the receiver
    ///      it validates. `market.debt` is the Comet's base by construction (`setMarket` enforces it).
    function encodeBorrow(address account, Market calldata market, uint256 amount)
        external
        view
        returns (address, uint256, bytes memory)
    {
        _requireSupportedMarket(market);
        account; // Comet delivers the borrow to msg.sender (the account); no receiver argument exists
        return (address(comet), 0, abi.encodeCall(IComet.withdraw, (Currency.unwrap(market.debt), amount)));
    }

    /// @inheritdoc ILendingAdapter
    /// @dev Encodes `IComet.supply(baseToken, amount)`, which repays the account's borrow (Comet has
    ///      no separate repay). The supplied amount is capped at the account's current borrow
    ///      (`borrowBalanceOf`, re-accrued to `block.timestamp` in the view), so a full repay
    ///      (`type(uint256).max`) or an over-sized repay clears the debt exactly and never converts the
    ///      overshoot into a base SUPPLY position (Comet turns any base supplied beyond the borrow into
    ///      a positive base balance rather than reverting).
    function encodeRepay(address account, Market calldata market, uint256 amount)
        external
        view
        returns (address, uint256, bytes memory)
    {
        _requireSupportedMarket(market);
        uint256 owed = comet.borrowBalanceOf(account);
        uint256 repayAmount = amount > owed ? owed : amount;
        return (address(comet), 0, abi.encodeCall(IComet.supply, (Currency.unwrap(market.debt), repayAmount)));
    }

    /// @inheritdoc ILendingAdapter
    /// @dev `collateralAmount` is `collateralBalanceOf(account, collateral)` (Comet collateral does not
    ///      accrue). `debtAmount` is `borrowBalanceOf(account)`, the base borrow accrued to
    ///      `block.timestamp`.
    function positionOf(address account, Market memory market)
        public
        view
        override(ILendingAdapter, PositionAmountResolver)
        returns (uint256 collateralAmount, uint256 debtAmount)
    {
        _requireSupportedMarket(market);
        collateralAmount = uint256(comet.collateralBalanceOf(account, Currency.unwrap(market.collateral)));
        debtAmount = comet.borrowBalanceOf(account);
    }

    /// @inheritdoc ILendingAdapter
    /// @dev Returns the collateral's LIQUIDATE collateral factor (already WAD), the liquidation
    ///      boundary. Comet enforces the tighter BORROW collateral factor at borrow time.
    function maxLtvWad(Market calldata market) external view returns (Ltv) {
        _requireSupportedMarket(market);
        return toLtv(comet.getAssetInfoByAddress(Currency.unwrap(market.collateral)).liquidateCollateralFactor);
    }

    /// @inheritdoc ILendingAdapter
    /// @dev Current LTV as `borrowValue * WAD / collateralValue`, both valued in USD via Comet's
    ///      price feeds (a common 1e8 price scale that cancels in the ratio). Returns
    ///      `type(uint256).max` (as an `Ltv`) when there is debt but zero collateral value, and 0 when
    ///      there is no debt.
    function currentLtvWad(address account, Market calldata market) external view returns (Ltv) {
        _requireSupportedMarket(market);
        (,, uint256 debtValue, uint256 collateralValue,) = _positionValues(account, market);
        return _ltv(debtValue, collateralValue);
    }

    /// @inheritdoc ILendingAdapter
    /// @dev Reads the position once and derives every field. Health factor is
    ///      `liquidateCF * collateralValue / debtValue` (WAD), i.e. `maxLtv / currentLtv`, and is
    ///      `type(uint256).max` when there is no debt.
    function describePosition(address account, Market calldata market)
        external
        view
        returns (PositionData memory data)
    {
        _requireSupportedMarket(market);
        (
            uint256 collateral,
            uint256 debt,
            uint256 debtValue,
            uint256 collateralValue,
            uint64 liquidateCollateralFactor
        ) = _positionValues(account, market);
        data = PositionData({
            collateralAmount: collateral,
            debtAmount: debt,
            maxLtv: toLtv(liquidateCollateralFactor),
            currentLtv: _ltv(debtValue, collateralValue),
            // maxLtv / currentLtv == liquidateCF * collateralValue / debtValue (WAD). Guard on
            // debtValue (the divisor), not the raw debt amount: a dust debt whose USD value rounds
            // down to zero is non-zero as a raw amount but would still divide by zero here.
            healthFactorWad: debtValue == 0
                ? type(uint256).max
                : Math.mulDiv(collateralValue, liquidateCollateralFactor, debtValue)
        });
    }

    /// @notice Reads the account's collateral, accrued base debt, their USD values, and the collateral
    ///         reserve's liquidation factor for a resolved market in a single pass, so `currentLtvWad`
    ///         and `describePosition` share one read.
    /// @param account The account to read.
    /// @param market The (collateral, debt) pair; must be allowlisted.
    /// @return collateral The account's supplied collateral, in the collateral token's native decimals.
    /// @return debt The account's accrued base borrow, in the base token's native decimals.
    /// @return debtValue The base debt valued in USD (Comet price scale).
    /// @return collateralValue The collateral valued in USD (Comet price scale).
    /// @return liquidateCollateralFactor The collateral's liquidation collateral factor (WAD).
    function _positionValues(address account, Market calldata market)
        internal
        view
        returns (
            uint256 collateral,
            uint256 debt,
            uint256 debtValue,
            uint256 collateralValue,
            uint64 liquidateCollateralFactor
        )
    {
        IComet.AssetInfo memory info = comet.getAssetInfoByAddress(Currency.unwrap(market.collateral));
        collateral = uint256(comet.collateralBalanceOf(account, Currency.unwrap(market.collateral)));
        debt = comet.borrowBalanceOf(account);
        collateralValue = _usd(collateral, comet.getPrice(info.priceFeed), info.scale);
        debtValue = _usd(debt, comet.getPrice(baseTokenPriceFeed()), baseScale);
        liquidateCollateralFactor = info.liquidateCollateralFactor;
    }

    /// @notice Values `amount` of an asset in USD at Comet's price scale: `amount * price / scale`.
    /// @param amount The asset amount, in the asset's native decimals.
    /// @param price The Comet USD price for the asset (1e8 scale).
    /// @param scale `10 ** assetDecimals` for the asset.
    /// @return The USD value at Comet's price scale (1e8), full-precision.
    function _usd(uint256 amount, uint256 price, uint256 scale) internal pure returns (uint256) {
        return Math.mulDiv(amount, price, scale);
    }

    /// @notice Current LTV from USD debt and collateral values. `type(uint256).max` when there is debt
    ///         but no collateral value; zero when there is no debt.
    /// @param debtValue The base debt valued in USD.
    /// @param collateralValue The collateral valued in USD.
    /// @return The current LTV as an `Ltv` (WAD, 1e18 == 100%).
    function _ltv(uint256 debtValue, uint256 collateralValue) internal pure returns (Ltv) {
        if (collateralValue == 0) return toLtv(debtValue == 0 ? 0 : type(uint256).max);
        return toLtv(Math.mulDiv(debtValue, WAD, collateralValue));
    }

    /// @notice Enables or disables routing for a `(collateral, debt)` pair. When enabling, `debt` must
    ///         be this Comet's base token and `collateral` must be a registered Comet collateral asset.
    ///         Owner-gated.
    /// @param collateral The collateral token of the pair (a Comet collateral asset).
    /// @param debt The debt token of the pair (must equal `baseToken`).
    /// @param allowed Whether the pair should be routable.
    function setMarket(Currency collateral, Currency debt, bool allowed) external {
        _onlyOwner();
        if (allowed) {
            if (Currency.unwrap(debt) != baseToken) revert DebtNotBaseToken(debt, baseToken);
            // getAssetInfoByAddress reverts for a non-collateral asset; treat that as unsupported
            try comet.getAssetInfoByAddress(Currency.unwrap(collateral)) returns (IComet.AssetInfo memory info) {
                if (info.asset != Currency.unwrap(collateral)) revert MarketNotSupported(collateral, debt);
            } catch {
                revert MarketNotSupported(collateral, debt);
            }
        }
        _markets.set(collateral, debt, allowed);
        emit MarketSet(Currency.unwrap(collateral), Currency.unwrap(debt), allowed);
    }

    /// @notice Reverts `MarketNotSupported` unless the `(collateral, debt)` pair is allowlisted.
    /// @param market The market pair to check.
    function _requireSupportedMarket(Market memory market) internal view {
        _markets.requireAllowed(market);
    }
}
