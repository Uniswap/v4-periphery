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

    /// @dev Thrown when an exact-output swap on `increasePosition` under-fills: the pool delivered
    ///      less than the requested `collateralToBuy` (a thin pool can hit the price limit before the
    ///      full output is bought). The increase is all-or-nothing, so it reverts rather than opening
    ///      a smaller position than requested.
    /// @param requested The collateral amount the increase asked the swap to deliver.
    /// @param received The collateral amount the swap actually delivered.
    error IncompleteFill(uint256 requested, uint256 received);

    /// @dev Thrown when an account-scoped action in an `execute` plan runs with no active account
    ///      set. A plan must open each account-scoped section with a `SET_ACCOUNT` action; the
    ///      curated entry points set the account themselves and never hit this.
    error NoActiveAccount();

    // -------------------------------------------------------------------------
    // Events
    // -------------------------------------------------------------------------

    /// @notice Emitted when leverage is opened or added via `increasePosition`. The first increase
    ///         for an account is paired with an `AccountCreated` event from the factory; subsequent
    ///         increases into the same account add leverage to the existing position. The
    ///         resulting-state fields let an indexer reconstruct the full position from this one log;
    ///         the entry price is `debtDrawn / collateralBought` in the market's native decimals.
    /// @param owner The position owner (the authenticated caller at the time of the call).
    /// @param account The MarginAccount holding the position.
    /// @param collateral The collateral currency of the market.
    /// @param debt The debt currency of the market.
    /// @param equity The equity the caller contributed, in the collateral token's native decimals
    ///        (the wrapped native amount when funded with ETH).
    /// @param collateralBought The collateral purchased by the increase swap, in the collateral
    ///        token's native decimals.
    /// @param debtDrawn The debt borrowed to fund the swap (the entry notional), in the debt token's
    ///        native decimals.
    /// @param collateralTotal The account's total collateral after the increase.
    /// @param debtTotal The account's total debt after the increase.
    /// @param currentLtv The position's LTV after the increase (WAD, 1e18 == 100%).
    /// @param maxLtv The market's max (liquidation) LTV (WAD, 1e18 == 100%).
    /// @param healthFactorWad The position health factor after the increase (WAD, 1e18 == 1.0).
    event PositionIncreased(
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

    /// @notice Emitted when a position is reduced or fully closed via `decreasePosition`. A full close
    ///         is indicated by `debtTotal == 0`, and the residual (realized PnL) returned to the caller
    ///         is `collateralReturned`. The resulting-state fields let an indexer reconstruct the full
    ///         position from this one log.
    /// @param owner The position owner (the authenticated caller).
    /// @param account The MarginAccount holding the position.
    /// @param collateral The collateral currency of the market.
    /// @param debt The debt currency of the market.
    /// @param debtRepaid The debt repaid, in the debt token's native decimals (all outstanding debt on
    ///        a full close).
    /// @param collateralWithdrawn The collateral removed from the lending position, in the collateral
    ///        token's native decimals (the swap cost on a partial decrease; all collateral on a full
    ///        close).
    /// @param collateralReturned The collateral returned to the caller, in the collateral token's
    ///        native decimals: zero on a partial decrease, the realized PnL on a full close.
    /// @param collateralTotal The account's total collateral after the operation (zero on a full close).
    /// @param debtTotal The account's total debt after the operation (zero on a full close).
    /// @param currentLtv The position's LTV after the operation (WAD, 1e18 == 100%).
    /// @param healthFactorWad The position health factor after the operation (WAD, 1e18 == 1.0).
    event PositionDecreased(
        address indexed owner,
        address indexed account,
        Currency collateral,
        Currency debt,
        uint256 debtRepaid,
        uint256 collateralWithdrawn,
        uint256 collateralReturned,
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

    /// @notice Parameters for opening or increasing a leveraged position (`increasePosition`).
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
    struct IncreaseParams {
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

    /// @notice Parameters for reducing (delevering) or fully closing a position.
    /// @dev Sells collateral to buy and repay `debtToRepay` of debt. A partial decrease keeps the
    ///      position open and shrinks it by the swap's collateral cost and the repaid debt, with
    ///      `maxLtvAfter` asserting the resulting LTV. Passing `debtToRepay == type(uint256).max`
    ///      instead fully closes the position: it repays all debt, withdraws all collateral, and
    ///      returns the residual (realized PnL) to the caller; a zero-debt position takes a swap-free
    ///      path, and `maxLtvAfter` is ignored on a full close.
    /// @param adapter The allowlisted lending adapter.
    /// @param market The (collateral, debt) pair defining the margin market.
    /// @param poolKey The v4 pool through which the decrease swap is routed.
    /// @param debtToRepay The exact amount of debt to repay (exact-output side of the swap), in the
    ///        debt token's native decimals, or `type(uint256).max` to fully close the position.
    /// @param maxCollateralIn The maximum collateral the caller will accept selling, in the
    ///        collateral token's native decimals. Must be non-zero on the swap path. The swap is a
    ///        single-hop exact-output swap, so this absolute cap fully bounds the worst-case swap
    ///        input and is the binding slippage protection. Derive it from a quote, not from spot
    ///        price. A zero-debt full close takes a swap-free path and ignores this field.
    /// @param minHopPriceX36 An optional additional per-hop price bound (X36 fixed-point). Zero
    ///        disables only this secondary check; it does not relax the binding `maxCollateralIn`
    ///        cap. Redundant with the absolute cap for a single hop, so it may be left zero.
    /// @param maxLtvAfter The maximum LTV the position may have after a partial decrease (WAD, 1e18 ==
    ///        100%). Must be non-zero for a partial decrease; ignored on a full close.
    /// @param subId The sub-account index identifying which MarginAccount to decrease or close.
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
    /// @param params See `IncreaseParams`.
    /// @return account The caller's MarginAccount holding the position.
    function increasePosition(IncreaseParams calldata params) external payable returns (address account);

    /// @notice Reduces the caller's position by repaying `debtToRepay` (funded by selling collateral),
    ///         or fully closes it when `debtToRepay == type(uint256).max` (repay all, withdraw all,
    ///         and return the residual realized PnL to the caller). A partial decrease keeps the
    ///         position open and enforces `params.maxLtvAfter`; a full close ignores it.
    /// @dev The adapter allowlist gates only exposure-increasing operations (increase, add
    ///      collateral), so a position can always be delevered or closed even if its adapter is later
    ///      removed from the allowlist. This is safe because the flow operates only on the caller's
    ///      own account, and the MarginAccount itself constrains the call target, receiver, and value
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

    /// @notice Executes an arbitrary plan of v4 routing and margin actions atomically in one
    ///         PoolManager unlock. The general-purpose counterpart to the curated entry points:
    ///         any composition the interpreter supports (swap, settle, take, wrap/unwrap/sweep,
    ///         and the account-scoped margin actions) runs as a single flash-accounted sequence.
    ///         `unlockData` is `abi.encode(bytes actions, bytes[] params)`, where `actions` is the
    ///         packed opcode string and `params[i]` is the encoded parameters for `actions[i]`.
    ///
    ///         Composing plans safely (the curated entry points enforce these for you; `execute`
    ///         does not):
    ///
    ///         1. Active account: open each account-scoped section with `SET_ACCOUNT(subId)`. The
    ///            account is always derived from the authenticated caller, never from calldata, so
    ///            a plan can only touch the caller's own accounts. The active account is cleared
    ///            when the call returns.
    ///         2. No entry validation: `execute` enforces no slippage, health, or fill bounds.
    ///            Encode `amountInMaximum`/`amountOutMinimum` on swaps, `ASSERT_FILL` after an
    ///            exact-output swap, and `ASSERT_HEALTH` yourself. The curated entry points remain
    ///            the guard-railed path.
    ///         3. Health: append `ASSERT_HEALTH` per touched (account, market), after each
    ///            `SET_ACCOUNT` section, not once at the end. A trailing assert only checks the
    ///            last active account.
    ///         4. Residuals: a plan MUST net the router to zero. Terminate with `SWEEP` for every
    ///            currency the plan may leave on the router. Balances left behind are claimable by
    ///            the next caller and are not protocol-protected.
    ///         5. Allowlist asymmetry: `ACCOUNT_SUPPLY_COLLATERAL` and `ACCOUNT_BORROW` require an
    ///            allowlisted adapter; withdraw, repay, and account-sweep do not, so a position is
    ///            always exitable.
    ///         6. `PULL_TO_ACCOUNT`: an encoded `0` amount reverts (it is not an `OPEN_DELTA`
    ///            full-balance sentinel here, unlike every other opcode); `CONTRACT_BALANCE` is
    ///            honored only on the router-balance path. Native currency is unsupported: wrap to
    ///            WETH first.
    ///         7. Signing an `execute` plan is equivalent to handing over the sub-account: a
    ///            malicious plan can borrow to the market maximum, withdraw all collateral, and
    ///            direct everything to an arbitrary address, with no token approval required (the
    ///            router is the account manager) - strictly worse than a token approval. Never
    ///            execute plans from untrusted builders; frontends must build the calldata.
    ///         8. Events: `execute` plans emit account-level events (`CollateralSupplied`,
    ///            `Borrowed`, `Repaid`, `Swept`, `AccountCreated`) but not the `Position*`
    ///            snapshot events the curated entry points emit.
    ///
    /// @param unlockData `abi.encode(bytes actions, bytes[] params)` describing the plan.
    /// @param deadline The Unix timestamp after which the call reverts `DeadlinePassed`.
    function execute(bytes calldata unlockData, uint256 deadline) external payable;
}
