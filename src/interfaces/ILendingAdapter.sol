// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {Market} from "../types/Market.sol";
import {Ltv} from "../types/Ltv.sol";
import {PositionData} from "../types/PositionData.sol";

/// @title ILendingAdapter
/// @author Uniswap Labs
/// @notice Lending-protocol-agnostic surface the margin router and account depend on. One singleton
///         instance per lending protocol; the specific market is selected by the `Market` key passed
///         to each call: its `(collateral, debt)` pair plus the adapter-specific `data` the adapter
///         decodes internally. Market selection is permissionless: the adapter holds no routing table
///         and routes any market its venue has, validating the key against the live venue on every
///         call. The caller is responsible for vetting the market it names.
/// @dev The adapter is an ENCODER: each `encode*` returns the call the `MarginAccount` performs as
///      itself (`account == msg.sender == position owner`), so no delegated authorization is ever
///      required. An implementation is TRUSTED to encode the authority-bearing fields faithfully:
///      `target` must be `lendingProtocol()`, `value` must be 0, `onBehalf` must be the `account`
///      argument, and a withdraw's recipient must be the `receiver` argument. The account validates the
///      `to` it is handed but never decodes the returned calldata, so nothing structurally verifies
///      those four obligations; `MarginAccount` documents how that trust is established per call path.
///      Borrowed funds are always delivered to the account, which forwards them to the
///      validated receiver, so `encodeBorrow` carries no receiver. Encode and read calls revert for a
///      market the venue does not have (`MarketNotSupported`, or a more specific adapter-declared
///      error naming the inconsistent field) and for `data` of the wrong shape (`InvalidMarketData`),
///      never a silent default market.
interface ILendingAdapter {
    /// @dev Thrown by an encode or read when the venue has no market for the key: the pair is not
    ///      listed, or the decoded `data` names a market that does not exist on the venue. Never a
    ///      silent default. Adapters may instead revert a more specific error of their own for a key
    ///      whose fields are mutually inconsistent (see each adapter).
    /// @param collateral The collateral currency of the unsupported market.
    /// @param debt The debt currency of the unsupported market.
    error MarketNotSupported(Currency collateral, Currency debt);

    /// @dev Thrown by an encode or read when `Market.data` is not the exact shape this adapter
    ///      decodes (wrong length). Adapters require the canonical length so one market has exactly
    ///      one key encoding.
    /// @param length The length of the `data` that was supplied.
    error InvalidMarketData(uint256 length);

    /// @notice The lending protocol singleton the account must call (the target of the account's
    ///         CALL). One address for every market this adapter routes to (e.g. Morpho Blue).
    /// @return The address of the underlying lending protocol singleton.
    function lendingProtocol() external view returns (address);

    /// @notice Whether the adapter can route `market` to a live venue market: `data` decodes and the
    ///         venue has the market it names. The non-reverting form of the check every encode and
    ///         read performs, for offchain validation before a transaction is built.
    /// @param market The market key to check.
    /// @return True if the key is routable; false otherwise.
    function isSupportedMarket(Market calldata market) external view returns (bool);

    /// @notice Encode the call to supply `amount` of `market.collateral` with `onBehalf = account`.
    /// @param account The MarginAccount supplying collateral; used as the `onBehalf` argument.
    /// @param market The market key identifying the target lending market.
    /// @param amount The amount of collateral to supply, in the collateral token's native decimals.
    /// @return target The call target (always `lendingProtocol()`).
    /// @return value The call value. Always 0 for the in-tree non-payable lending protocols; the
    ///         account forwards whatever value the adapter encodes (see `MarginAccount._execCall`).
    /// @return callData The calldata the account executes against `target`.
    function encodeSupplyCollateral(address account, Market calldata market, uint256 amount)
        external
        view
        returns (address target, uint256 value, bytes memory callData);

    /// @notice Encode the call the account runs immediately after a supply to make the supplied
    ///         reserve usable as collateral, for venues that do not enable it implicitly. Aave (v3 and
    ///         v4) require an explicit enable (`setUserUseReserveAsCollateral` / `setUsingAsCollateral`)
    ///         which acts on the calling account, so the account must run it itself; Morpho and
    ///         Compound treat supplied collateral as collateral automatically and return empty
    ///         `callData`.
    /// @dev The account executes `callData` against `target` only when `callData` is non-empty;
    ///      an empty `callData` is the skip signal. Moves no tokens (no approval needed). Idempotent
    ///      where implemented, so it is safe to run on every supply, including a top-up. An adapter
    ///      whose venue needs no enable step may return the skip signal without decoding the key:
    ///      the account only calls this right after `encodeSupplyCollateral` for the same market,
    ///      which has already validated it. This is the one encoder exempt from the key-validation
    ///      contract above.
    /// @param account The MarginAccount whose reserve is enabled as collateral.
    /// @param market The market key identifying the target lending market.
    /// @return target The call target (`lendingProtocol()`) when `callData` is non-empty.
    /// @return value The call value. Always 0 for the in-tree non-payable lending protocols.
    /// @return callData The calldata to execute, or empty bytes to skip.
    function encodeEnableCollateral(address account, Market calldata market)
        external
        view
        returns (address target, uint256 value, bytes memory callData);

    /// @notice Encode the call to withdraw `amount` of `market.collateral` to `receiver`.
    /// @param account The MarginAccount whose collateral is being withdrawn; used as `onBehalf`.
    /// @param market The market key identifying the target lending market.
    /// @param amount The amount of collateral to withdraw, in the collateral token's native decimals.
    /// @param receiver The address that will receive the withdrawn collateral. The account enforces
    ///        that this is the manager or owner before executing.
    /// @return target The call target (always `lendingProtocol()`).
    /// @return value The call value. Always 0 for non-payable lending protocols.
    /// @return callData The calldata the account executes against `target`.
    function encodeWithdrawCollateral(address account, Market calldata market, uint256 amount, address receiver)
        external
        view
        returns (address target, uint256 value, bytes memory callData);

    /// @notice Encode the call to borrow `amount` of `market.debt` to the account itself.
    /// @dev The borrowed asset is delivered to the account, which forwards it to the manager or
    ///      owner receiver it validates. The receiver is therefore not an `encodeBorrow` concern.
    /// @param account The MarginAccount whose borrowing capacity is used; used as `onBehalf` and as
    ///        the borrow recipient so the account holds the funds before forwarding.
    /// @param market The market key identifying the target lending market.
    /// @param amount The amount of debt to borrow, in the debt token's native decimals.
    /// @return target The call target (always `lendingProtocol()`).
    /// @return value The call value. Always 0 for non-payable lending protocols.
    /// @return callData The calldata the account executes against `target`.
    function encodeBorrow(address account, Market calldata market, uint256 amount)
        external
        view
        returns (address target, uint256 value, bytes memory callData);

    /// @notice Encode the call to repay `amount` of `market.debt`.
    /// @dev Passing `amount == type(uint256).max`, or any `amount` at or above the reported debt,
    ///      triggers a full repay resolved by the adapter in the venue's own terms: Morpho burns the
    ///      entire borrow-share balance (avoiding interest dust and the rounding underflow an
    ///      asset-denominated exact repay would hit), Aave v3/v4 pass the venue's native repay-all
    ///      sentinel, and Compound clamps to the outstanding base debt. When the account has no debt
    ///      to repay, the adapter returns empty `callData` and the account skips the call, so a
    ///      generic "repay then withdraw" exit plan works against a debt-free position.
    /// @param account The MarginAccount repaying the debt; used as `onBehalf`.
    /// @param market The market key identifying the target lending market.
    /// @param amount The amount of debt to repay in native decimals, or `type(uint256).max` to repay
    ///        the full debt.
    /// @return target The call target (always `lendingProtocol()`).
    /// @return value The call value. Always 0 for non-payable lending protocols.
    /// @return callData The calldata the account executes against `target`, or empty bytes to skip.
    function encodeRepay(address account, Market calldata market, uint256 amount)
        external
        view
        returns (address target, uint256 value, bytes memory callData);

    /// @notice Current position for `account` in `market`, as current assets.
    /// @dev `debtAmount` always includes interest accrued to the current timestamp. `collateralAmount`
    ///      is the venue's current balance: interest-accrued where collateral earns interest (Aave
    ///      v3 aToken balances rebase; Aave v4 reports the Spoke's accrued supplied assets) and the
    ///      raw supplied balance where it does not (Morpho Blue and Comet collateral earn no
    ///      interest). In every case it is the amount a full withdrawal
    ///      would return, so callers can rely on these for an accurate snapshot of current obligations.
    /// @param account The MarginAccount to query.
    /// @param market The market key identifying the target lending market.
    /// @return collateralAmount The account's supplied collateral balance, in the collateral token's
    ///         native decimals.
    /// @return debtAmount The account's outstanding debt with accrued interest, in the debt token's
    ///         native decimals.
    function positionOf(address account, Market calldata market)
        external
        view
        returns (uint256 collateralAmount, uint256 debtAmount);

    /// @notice The market's maximum LTV (liquidation LTV), expressed as a WAD-typed `Ltv`
    ///         where 1e18 == 100%.
    /// @param market The market key identifying the target lending market.
    /// @return The liquidation LTV as an `Ltv` (WAD, 1e18 == 100%).
    function maxLtvWad(Market calldata market) external view returns (Ltv);

    /// @notice The account's current LTV in `market`, expressed as a WAD-typed `Ltv`
    ///         where 1e18 == 100%.
    /// @dev This is the value `MarginRouter`'s post-action health check consumes. On venues with
    ///      account-level reads (Aave v3/v4 on both sides; Compound's base debt) it is an
    ///      account-level value, so it equals the position's LTV only under the
    ///      one-position-per-`subId` usage requirement documented on each adapter.
    /// @param account The MarginAccount to query.
    /// @param market The market key identifying the target lending market.
    /// @return The current LTV as an `Ltv` (WAD, 1e18 == 100%).
    function currentLtvWad(address account, Market calldata market) external view returns (Ltv);

    /// @notice A consolidated snapshot of `account`'s position in `market`: collateral and debt
    ///         amounts, the market's max (liquidation) LTV, the current LTV, and the health factor.
    /// @dev Equivalent to reading `positionOf`, `maxLtvWad`, and `currentLtvWad` together, plus a
    ///      health factor, in a single call. The health factor is `maxLtv / currentLtv` in WAD on
    ///      Morpho and Compound; Aave v3/v4 report the protocol's own liquidation-threshold-weighted
    ///      health factor, which only approximates that ratio. It is `type(uint256).max` when there
    ///      is no debt and zero when debt is held against zero collateral value. For adapters with
    ///      account-level reads (Aave v3/v4 on both sides; Compound's base debt) the LTV and health
    ///      factor equal the position's values only when the account holds a single position on that
    ///      protocol (one position per `subId`).
    /// @param account The MarginAccount to query.
    /// @param market The market key identifying the target lending market.
    /// @return data The consolidated position snapshot; see `PositionData`.
    function describePosition(address account, Market calldata market) external view returns (PositionData memory data);
}
