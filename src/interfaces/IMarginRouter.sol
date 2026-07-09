// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {ILendingAdapter} from "./ILendingAdapter.sol";
import {Market} from "../types/Market.sol";
import {Ltv} from "../types/Ltv.sol";

/// @title IMarginRouter
/// @author Uniswap Labs
/// @notice Entry points for opening, closing, and topping up leveraged spot positions. Each call
///         operates on the caller's own MarginAccount, derived from the authenticated caller and a
///         subId, never from a caller-supplied account address. Leverage is built as a single
///         flash-style swap inside one PoolManager unlock: borrow the debt, swap it into collateral,
///         supply the collateral, and draw the debt to settle the swap.
interface IMarginRouter {
    // -------------------------------------------------------------------------
    // Errors
    // -------------------------------------------------------------------------

    /// @dev Thrown when `block.timestamp` has passed the caller-supplied deadline.
    /// @param deadline The deadline that was exceeded.
    error DeadlinePassed(uint256 deadline);

    /// @dev Thrown when a required slippage bound (e.g. `maxDebtIn`, `maxCollateralIn`) or a
    ///      required health bound (`maxLtvAfter`) is zero. Leaving these bounds unset would allow
    ///      a swap to execute at an arbitrary price or leave a position in an unchecked state.
    error SlippageBoundRequired();

    /// @dev Thrown when an operation would create or leave a position with LTV above the adapter's
    ///      maximum liquidation LTV.
    error PositionUnhealthy();

    /// @dev Thrown when a flow is called with a lending adapter that governance has not allowlisted.
    ///      A non-allowlisted adapter could redirect equity to an arbitrary destination.
    /// @param adapter The disallowed adapter address that was supplied.
    error AdapterNotAllowed(address adapter);

    /// @dev Thrown when native ETH is sent with a position call but the market's collateral is not
    ///      WETH. ETH is wrapped to WETH before crediting the account; mismatching collateral would
    ///      leave the account funded in the wrong token.
    error NativeCollateralMismatch();

    /// @dev Thrown when an exact-output swap on `openPosition` under-fills: the pool delivered less
    ///      than the requested `collateralToBuy` (a thin pool can hit the price limit before the full
    ///      output is bought). The open is all-or-nothing, so it reverts rather than opening a smaller
    ///      position than requested.
    /// @param requested The collateral amount the open asked the swap to deliver.
    /// @param received The collateral amount the swap actually delivered.
    error IncompleteFill(uint256 requested, uint256 received);

    // -------------------------------------------------------------------------
    // Events
    // -------------------------------------------------------------------------

    /// @notice Emitted when leverage is opened or added via `openPosition`. The first open for an
    ///         account is paired with an `AccountCreated` event from the factory; subsequent opens
    ///         into the same account add leverage to the existing position. The resulting-state
    ///         fields let an indexer reconstruct the full position from this one log; the entry price
    ///         is `debtDrawn / collateralBought` in the market's native decimals.
    /// @param owner The position owner (the authenticated caller at the time of the call).
    /// @param account The MarginAccount holding the position.
    /// @param collateral The collateral currency of the market.
    /// @param debt The debt currency of the market.
    /// @param equity The equity the caller contributed, in the collateral token's native decimals
    ///        (the wrapped native amount when opened with ETH).
    /// @param collateralBought The collateral purchased by the opening swap, in the collateral
    ///        token's native decimals.
    /// @param debtDrawn The debt borrowed to fund the swap (the entry notional), in the debt token's
    ///        native decimals.
    /// @param collateralTotal The account's total collateral after the open.
    /// @param debtTotal The account's total debt after the open.
    /// @param currentLtv The position's LTV after the open (WAD, 1e18 == 100%).
    /// @param maxLtv The market's max (liquidation) LTV (WAD, 1e18 == 100%).
    /// @param healthFactorWad The position health factor after the open (WAD, 1e18 == 1.0).
    event PositionOpened(
        address indexed owner,
        address indexed account,
        Currency collateral,
        Currency debt,
        uint256 equity,
        uint256 collateralBought,
        uint256 debtDrawn,
        uint256 collateralTotal,
        uint256 debtTotal,
        Ltv currentLtv,
        Ltv maxLtv,
        uint256 healthFactorWad
    );

    /// @notice Emitted when a position is fully closed.
    /// @param owner The position owner (the authenticated caller).
    /// @param account The MarginAccount that held the position.
    /// @param collateral The collateral currency of the market.
    /// @param debt The debt currency of the market.
    /// @param debtRepaid The debt cleared by the close, in the debt token's native decimals (zero for
    ///        a debt-free position).
    /// @param collateralWithdrawn The collateral pulled from the lending position, in the collateral
    ///        token's native decimals.
    /// @param collateralReturned The residual collateral (realized PnL) returned to the caller, in
    ///        the collateral token's native decimals.
    event PositionClosed(
        address indexed owner,
        address indexed account,
        Currency collateral,
        Currency debt,
        uint256 debtRepaid,
        uint256 collateralWithdrawn,
        uint256 collateralReturned
    );

    /// @notice Emitted when a position is partially delevered via `decreasePosition`.
    /// @param owner The position owner (the authenticated caller).
    /// @param account The MarginAccount holding the position.
    /// @param collateral The collateral currency of the market.
    /// @param debt The debt currency of the market.
    /// @param debtRepaid The debt repaid by the decrease, in the debt token's native decimals.
    /// @param collateralSold The collateral consumed by the delever swap, in the collateral token's
    ///        native decimals.
    /// @param collateralTotal The account's total collateral after the decrease.
    /// @param debtTotal The account's total debt after the decrease.
    /// @param currentLtv The position's LTV after the decrease (WAD, 1e18 == 100%).
    /// @param healthFactorWad The position health factor after the decrease (WAD, 1e18 == 1.0).
    event PositionDecreased(
        address indexed owner,
        address indexed account,
        Currency collateral,
        Currency debt,
        uint256 debtRepaid,
        uint256 collateralSold,
        uint256 collateralTotal,
        uint256 debtTotal,
        Ltv currentLtv,
        uint256 healthFactorWad
    );

    /// @notice Emitted when collateral is added to a position via `addCollateral`.
    /// @param owner The position owner (the authenticated caller).
    /// @param account The MarginAccount that received the collateral.
    /// @param collateral The collateral currency supplied.
    /// @param amount The amount of collateral added, in the collateral token's native decimals.
    /// @param collateralTotal The account's total collateral after the add.
    /// @param debtTotal The account's total debt after the add (unchanged by the add).
    /// @param currentLtv The position's LTV after the add (WAD, 1e18 == 100%).
    /// @param healthFactorWad The position health factor after the add (WAD, 1e18 == 1.0).
    event CollateralAdded(
        address indexed owner,
        address indexed account,
        Currency collateral,
        uint256 amount,
        uint256 collateralTotal,
        uint256 debtTotal,
        Ltv currentLtv,
        uint256 healthFactorWad
    );

    // -------------------------------------------------------------------------
    // Param structs
    // -------------------------------------------------------------------------

    /// @notice Parameters for opening or increasing a leveraged position.
    /// @dev The swap always sells the market's debt to buy its collateral. The trade direction is
    ///      set entirely by the market's (collateral, debt) assignment: the position is long the
    ///      collateral and short the debt. Equity is provided in the collateral currency.
    /// @param adapter The allowlisted lending adapter that encodes and reads lending protocol calls.
    /// @param market The (collateral, debt) pair defining the margin market. This pairing sets the
    ///        trade direction: long the collateral, short the debt.
    /// @param poolKey The v4 pool through which the leverage swap is routed.
    /// @param equity The amount of collateral the caller contributes as equity, in the collateral
    ///        token's native decimals. Ignored when `msg.value > 0` (native ETH is used instead).
    /// @param collateralToBuy The exact amount of collateral to purchase from the swap (exact-output
    ///        side), in the collateral token's native decimals.
    /// @param maxDebtIn The maximum debt the caller will accept as the swap input, in the debt
    ///        token's native decimals. Must be non-zero. The swap is a single-hop exact-output swap,
    ///        so this absolute cap fully bounds the worst-case swap input and is the binding slippage
    ///        protection. Derive it from a quote, not from spot price.
    /// @param minHopPriceX36 An optional additional per-hop price bound, encoded as a per-hop price
    ///        in X36 fixed-point. Zero disables only this secondary check; it does not relax the
    ///        binding `maxDebtIn` cap. Redundant with the absolute cap for a single hop, so it may be
    ///        left zero.
    /// @param subId A caller-chosen sub-account index allowing one address to hold multiple
    ///        independent positions. The (caller, subId) pair determines the MarginAccount address.
    /// @param deadline A Unix timestamp; the call reverts if `block.timestamp` exceeds this value.
    struct OpenParams {
        ILendingAdapter adapter;
        Market market;
        PoolKey poolKey;
        uint256 equity;
        uint128 collateralToBuy;
        uint128 maxDebtIn;
        uint256 minHopPriceX36;
        uint256 subId;
        uint256 deadline;
    }

    /// @notice Parameters for fully closing a leveraged position.
    /// @dev The swap sells collateral to buy exactly the current debt (exact-output), which is
    ///      then repaid in full. The remaining collateral (realized PnL) is returned to the caller.
    /// @param adapter The allowlisted lending adapter.
    /// @param market The (collateral, debt) pair defining the margin market.
    /// @param poolKey The v4 pool through which the closing swap is routed.
    /// @param maxCollateralIn The maximum collateral the caller will accept as the swap input, in
    ///        the collateral token's native decimals. Must be non-zero on the swap path. The swap is
    ///        a single-hop exact-output swap, so this absolute cap fully bounds the worst-case swap
    ///        input and is the binding slippage protection. Derive it from a quote, not from spot
    ///        price. A zero-debt close takes a swap-free path and ignores this field.
    /// @param minHopPriceX36 An optional additional per-hop price bound (X36 fixed-point). Zero
    ///        disables only this secondary check; it does not relax the binding `maxCollateralIn`
    ///        cap. Redundant with the absolute cap for a single hop, so it may be left zero.
    /// @param subId The sub-account index identifying which MarginAccount to close.
    /// @param deadline A Unix timestamp; the call reverts if `block.timestamp` exceeds this value.
    struct CloseParams {
        ILendingAdapter adapter;
        Market market;
        PoolKey poolKey;
        uint128 maxCollateralIn;
        uint256 minHopPriceX36;
        uint256 subId;
        uint256 deadline;
    }

    /// @notice Parameters for partially reducing (delevering) a position.
    /// @dev Sells collateral to buy and repay `debtToRepay` of debt. The position stays open and
    ///      shrinks by the swap's collateral cost and the repaid debt. `maxLtvAfter` asserts the
    ///      resulting LTV after the operation; pass zero to skip the check (not recommended).
    /// @param adapter The allowlisted lending adapter.
    /// @param market The (collateral, debt) pair defining the margin market.
    /// @param poolKey The v4 pool through which the decrease swap is routed.
    /// @param debtToRepay The exact amount of debt to repay (exact-output side of the swap), in
    ///        the debt token's native decimals.
    /// @param maxCollateralIn The maximum collateral the caller will accept selling, in the
    ///        collateral token's native decimals. Must be non-zero. The swap is a single-hop
    ///        exact-output swap, so this absolute cap fully bounds the worst-case swap input and is
    ///        the binding slippage protection. Derive it from a quote, not from spot price.
    /// @param minHopPriceX36 An optional additional per-hop price bound (X36 fixed-point). Zero
    ///        disables only this secondary check; it does not relax the binding `maxCollateralIn`
    ///        cap. Redundant with the absolute cap for a single hop, so it may be left zero.
    /// @param maxLtvAfter The maximum LTV the position may have after the decrease (WAD, 1e18 ==
    ///        100%). Must be non-zero; prevents a partial delever from inadvertently worsening LTV.
    /// @param subId The sub-account index identifying which MarginAccount to decrease.
    /// @param deadline A Unix timestamp; the call reverts if `block.timestamp` exceeds this value.
    struct DecreaseParams {
        ILendingAdapter adapter;
        Market market;
        PoolKey poolKey;
        uint256 debtToRepay;
        uint128 maxCollateralIn;
        uint256 minHopPriceX36;
        Ltv maxLtvAfter;
        uint256 subId;
        uint256 deadline;
    }

    /// @notice Parameters for adding collateral to an existing position without changing leverage.
    /// @param adapter The allowlisted lending adapter.
    /// @param market The (collateral, debt) pair defining the margin market.
    /// @param amount The amount of collateral to add, in the collateral token's native decimals.
    ///        Ignored when `msg.value > 0` (native ETH is wrapped and used instead).
    /// @param subId The sub-account index identifying which MarginAccount receives the collateral.
    ///        The account is deployed if it does not yet exist.
    /// @param deadline A Unix timestamp; the call reverts if `block.timestamp` exceeds this value.
    struct AddCollateralParams {
        ILendingAdapter adapter;
        Market market;
        uint256 amount;
        uint256 subId;
        uint256 deadline;
    }

    // -------------------------------------------------------------------------
    // External functions
    // -------------------------------------------------------------------------

    /// @notice Opens or adds to a leveraged position for the caller, deploying their MarginAccount if
    ///         needed. Equity is ERC-20 collateral pulled via Permit2, or native ETH sent as
    ///         `msg.value` (which the router wraps to WETH; the market collateral must then be WETH).
    ///         When `msg.value` is non-zero it is used as the equity and `params.equity` is ignored.
    ///         Calling again on an account that already holds a position adds leverage to it; set
    ///         `equity` to zero and send no value for a pure leverage increase with no new equity.
    /// @param params See `OpenParams`.
    /// @return account The caller's MarginAccount holding the position.
    function openPosition(OpenParams calldata params) external payable returns (address account);

    /// @notice Fully closes the caller's position, returning all residual collateral (realized PnL)
    ///         to the caller.
    /// @dev The adapter allowlist gates only exposure-increasing operations (open, increase, add
    ///      collateral), so a position can always be unwound even if its adapter is later removed
    ///      from the allowlist. This is safe because the flow operates only on the caller's own
    ///      account, and the MarginAccount itself constrains the call target, receiver, and value
    ///      regardless of the adapter.
    /// @param params See `CloseParams`.
    /// @return account The caller's MarginAccount.
    function closePosition(CloseParams calldata params) external returns (address account);

    /// @notice Partially reduces the caller's position by repaying `debtToRepay`, funded by selling
    ///         collateral. The position stays open and shrinks. A health check on the resulting LTV
    ///         is enforced via `params.maxLtvAfter`.
    /// @dev The adapter allowlist gates only exposure-increasing operations (open, increase, add
    ///      collateral), so a position can always be delevered even if its adapter is later removed
    ///      from the allowlist. This is safe because the flow operates only on the caller's own
    ///      account, and the MarginAccount itself constrains the call target, receiver, and value
    ///      regardless of the adapter.
    /// @param params See `DecreaseParams`.
    /// @return account The caller's MarginAccount.
    function decreasePosition(DecreaseParams calldata params) external returns (address account);

    /// @notice Adds collateral to the caller's position without changing debt, deploying their
    ///         MarginAccount if needed. Collateral is pulled via Permit2, or sent as native ETH
    ///         (wrapped to WETH; the market collateral must then be WETH).
    /// @param params See `AddCollateralParams`.
    /// @return account The caller's MarginAccount.
    function addCollateral(AddCollateralParams calldata params) external payable returns (address account);

    /// @notice The deterministic MarginAccount address for a given owner and subId, whether or not
    ///         the account has been deployed yet.
    /// @param owner The account owner whose address is used in the CREATE2 salt.
    /// @param subId The sub-account index.
    /// @return The predicted MarginAccount clone address.
    function accountOf(address owner, uint256 subId) external view returns (address);
}
