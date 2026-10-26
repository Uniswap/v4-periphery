// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {IUniversalRouter} from "universal-router/contracts/interfaces/IUniversalRouter.sol";

import {V4Router} from "./V4Router.sol";
import {ReentrancyLock} from "./base/ReentrancyLock.sol";
import {Permit2Forwarder} from "./base/Permit2Forwarder.sol";
import {Multicall_v4} from "./base/Multicall_v4.sol";
import {NativeWrapper} from "./base/NativeWrapper.sol";
import {IWETH9} from "./interfaces/external/IWETH9.sol";
import {Actions} from "./libraries/Actions.sol";
import {ActionConstants} from "./libraries/ActionConstants.sol";
import {CalldataDecoder} from "./libraries/CalldataDecoder.sol";

import {IMarginRouter} from "./interfaces/IMarginRouter.sol";
import {IMarginAccount} from "./interfaces/IMarginAccount.sol";
import {ILendingAdapter} from "./interfaces/ILendingAdapter.sol";
import {MarginAccountFactory} from "./MarginAccountFactory.sol";
import {MarginActions} from "./libraries/MarginActions.sol";
import {MarginCalldataDecoder} from "./libraries/MarginCalldataDecoder.sol";
import {TransientPlanState} from "./libraries/TransientPlanState.sol";
import {Market} from "./types/Market.sol";
import {Ltv} from "./types/Ltv.sol";
import {Units} from "./libraries/Units.sol";
import {PositionData} from "./types/PositionData.sol";

/// @title MarginRouter
/// @author Uniswap Labs
/// @notice The entry point for the margin-trading suite. Composes the v4 action machinery and
///         builds each leveraged position as a single flash-style swap inside one PoolManager
///         unlock: borrow the debt, swap it into collateral, supply the collateral, then draw the
///         debt back to settle. Each operation runs against the caller's own MarginAccount, derived
///         from the authenticated caller (never from a caller-supplied address). The router is the
///         manager of every account it deploys, so it can drive their lending primitives.
///
///         The router has no governance and no allowlist. The caller chooses both the lending adapter
///         (the venue) and the market within it (`Market`: the `(collateral, debt)` pair plus
///         adapter-decoded `data`); the adapter validates the market against the live venue, and the
///         caller, or the app that built the transaction, vets the adapter it names. A hostile adapter
///         reaches only the caller's own account (see `MarginAccount`). The supported venues list
///         standard ERC-20 markets (no fee-on-transfer or rebasing tokens), under which every curated
///         flow (the fixed plan behind `increasePosition`, `decreasePosition`, or `addCollateral`, as
///         opposed to a plan the caller builds for `execute`) nets to zero with no router residual by
///         construction; a non-standard token fails the flows' fill and settle assertions rather than
///         leaving a residual.
///
///         The `execute` entry point runs an arbitrary caller-supplied plan of the same actions.
///         It does not guarantee zero residual: a plan MUST net the router itself (terminate with
///         `SWEEP`), because any balance left on the router is claimable by the next caller. See
///         `IMarginRouter.execute` for the full plan-composition contract.
/// @custom:security-contact security@uniswap.org
contract MarginRouter is
    IMarginRouter,
    V4Router,
    ReentrancyLock,
    Permit2Forwarder,
    Multicall_v4,
    NativeWrapper,
    MarginAccountFactory
{
    using MarginCalldataDecoder for bytes;
    using CalldataDecoder for bytes;
    using SafeCast for uint256;
    using CurrencyLibrary for Currency;
    using SafeERC20 for IERC20;

    /// @dev Reverts `DeadlinePassed` if `block.timestamp` has passed `deadline`.
    modifier checkDeadline(uint256 deadline) {
        if (block.timestamp > deadline) revert DeadlinePassed(deadline);
        _;
    }

    /// @notice Deploys the margin router.
    /// @param poolManager_ The v4 PoolManager singleton the router unlocks for every position flow.
    /// @param permit2_ The Permit2 contract used to pull caller equity and settle swaps.
    /// @param weth9_ The canonical 1:1 wrapped native (WETH9) used to wrap native equity, or the zero
    ///        address on a chain without one, which makes every native path revert
    ///        `NativeNotSupported` (see `IMarginRouter.NativeNotSupported`).
    /// @param accountImplementation_ The MarginAccount implementation cloned for each account.
    constructor(IPoolManager poolManager_, IAllowanceTransfer permit2_, IWETH9 weth9_, address accountImplementation_)
        V4Router(poolManager_)
        Permit2Forwarder(permit2_)
        NativeWrapper(weth9_)
        MarginAccountFactory(accountImplementation_)
    {}

    /// @inheritdoc IMarginRouter
    function increasePosition(IncreaseParams calldata params)
        external
        payable
        isNotLocked
        checkDeadline(params.deadline)
        returns (address account)
    {
        uint256 debtBefore;
        (account, debtBefore) = _increase(params);
        // best-effort rich event: a venue read that reverts (oracle downtime) must not roll back the
        // completed increase, and the PositionUpdated snapshots emitted inside the unlock already
        // carry the resulting state. The debt delta saturates at zero because a permissionless
        // onBehalf repay landing inside the transaction can leave the debt below its start.
        try params.adapter.describePosition(account, params.market) returns (PositionData memory position) {
            emit PositionIncreased(
                msgSender(),
                account,
                params.market.collateral,
                params.market.debt,
                params.market.data,
                msg.value > 0 ? msg.value : params.equity,
                params.collateralToBuy,
                position.debtAmount > debtBefore ? position.debtAmount - debtBefore : 0,
                position.collateralAmount,
                position.debtAmount,
                position.currentLtv,
                position.maxLtv,
                position.healthFactorWad
            );
        } catch {}
    }

    /// @inheritdoc IMarginRouter
    /// @dev `DecreaseParams.debtToRepay == type(uint256).max` closes the position; any other value
    ///      is a partial decrease. Both run the same plan (`_decreasePlan`) with different amounts
    ///      and assert different things afterward, so each has its own linear path.
    function decreasePosition(DecreaseParams calldata params)
        external
        isNotLocked
        checkDeadline(params.deadline)
        returns (address account)
    {
        account = accountOf(msgSender(), params.subId);
        if (params.debtToRepay == type(uint256).max) _closePosition(params, account);
        else _partialDecrease(params, account);
    }

    /// @notice Full close: repay all, withdraw all, and return the realized collateral plus any debt
    ///         the route over-bought to the caller. A debt-free position (funded only through
    ///         `addCollateral`, repaid out of band, or fully liquidated) needs no swap, so its
    ///         collateral is withdrawn straight to the caller.
    /// @param params The decrease parameters.
    /// @param account The caller's MarginAccount.
    function _closePosition(DecreaseParams calldata params, address account) private {
        (uint256 collateralBefore, uint256 debt) = params.adapter.positionOf(account, params.market);

        if (debt == 0) {
            if (collateralBefore > 0) {
                IMarginAccount(account).withdrawCollateral(params.adapter, params.market, collateralBefore, msgSender());
            }
            // no unlock ran, so no action handler emitted the snapshot; emit the terminal one here
            (bool read, PositionData memory position) = _readPosition(params.adapter, params.market, account);
            if (read) _emitPosition(params.market, account, position);
            _emitClosed(params, account, 0, collateralBefore, collateralBefore);
            return;
        }

        if (params.maxCollateralIn == 0) revert SlippageBoundRequired();

        // the route must deliver at least the current debt; repay all so no dust remains (resolved by
        // the adapter in the venue's own terms); withdraw everything; no health bound, since the
        // position ends empty
        uint256 balanceBefore = params.market.collateral.balanceOfSelf();
        (bytes memory actions, bytes[] memory actionParams) =
            _decreasePlan(params, account, debt, type(uint256).max, collateralBefore, Ltv.wrap(0));
        _unlockAs(account, actions, actionParams);

        // a route quoted with an accrual buffer over-buys debt, which repay-all leaves in the account;
        // return it to the caller
        uint256 debtOver = params.market.debt.balanceOf(account);
        if (debtOver > 0) IMarginAccount(account).sweep(params.market.debt, debtOver, msgSender());

        // the withdrawn collateral beyond what the swap consumed is the realized PnL
        uint256 residual = _returnCollateralGain(params.market.collateral, balanceBefore);
        _emitClosed(params, account, debt, collateralBefore, residual);
    }

    /// @notice Partial decrease: repay exactly `debtToRepay`, withdraw only the collateral the swap
    ///         consumed, and enforce the mandatory resulting-health bound.
    /// @param params The decrease parameters.
    /// @param account The caller's MarginAccount.
    function _partialDecrease(DecreaseParams calldata params, address account) private {
        // the repay must be non-zero (a zero would feed the exact-output swap a zero, which the
        // PoolManager rejects), and the health bound must be set and able to bind: at or above 100%
        // it can never be exceeded, so it would count as set yet leave ASSERT_HEALTH a no-op
        if (params.debtToRepay == 0) revert ZeroAmount();
        if (Ltv.unwrap(params.maxLtvAfter) == 0) revert LtvBoundRequired();
        if (Ltv.unwrap(params.maxLtvAfter) >= Units.WAD) revert IneffectiveLtvBound(params.maxLtvAfter);

        (uint256 collateralBefore, uint256 debt) = params.adapter.positionOf(account, params.market);
        // nothing to repay: the swap would buy debt tokens no repay consumes and strand them in the
        // account (only a close sweeps the surplus). This also covers a market key the account holds
        // no position in.
        if (debt == 0) revert NoDebtToRepay();
        if (params.maxCollateralIn == 0) revert SlippageBoundRequired();

        // the route must deliver debtToRepay; repay exactly that; withdraw what the swap consumed
        // (OPEN_DELTA: the router's remaining collateral debt to the pool); enforce maxLtvAfter
        uint256 balanceBefore = params.market.collateral.balanceOfSelf();
        // fail-closed: the plan's ACCOUNT_REPAY overwrites this with what it actually repaid
        TransientPlanState.setLastRepaid(0);
        (bytes memory actions, bytes[] memory actionParams) = _decreasePlan(
            params,
            account,
            params.debtToRepay,
            params.debtToRepay,
            uint256(ActionConstants.OPEN_DELTA),
            params.maxLtvAfter
        );
        _unlockAs(account, actions, actionParams);

        // the pre-unlock debt read cannot see a repay that lands inside the unlock (venues accept
        // permissionless onBehalf repays, and route-path code can execute one). With the debt cleared
        // mid-transaction the repay leg no-ops and the bought debt tokens strand in the account, so
        // require a measured repay. A close tolerates the no-op, since it sweeps the surplus back.
        if (TransientPlanState.lastRepaid() == 0) revert NoDebtToRepay();

        // normally zero: the withdraw is sized to exactly what the swap consumed
        uint256 residual = _returnCollateralGain(params.market.collateral, balanceBefore);

        // best-effort rich event: a venue read that reverts (oracle downtime) must not roll back the
        // completed decrease, and the PositionUpdated snapshots emitted inside the unlock already
        // carry the resulting state. The collateral delta saturates at zero because a permissionless
        // onBehalf supply landing inside the transaction can leave the collateral above its start.
        try params.adapter.describePosition(account, params.market) returns (PositionData memory position) {
            emit PositionDecreased(
                msgSender(),
                account,
                params.market.collateral,
                params.market.debt,
                params.market.data,
                params.debtToRepay,
                collateralBefore > position.collateralAmount ? collateralBefore - position.collateralAmount : 0,
                residual,
                position.collateralAmount,
                position.debtAmount,
                position.currentLtv,
                position.healthFactorWad
            );
        } catch {}
    }

    /// @notice Builds the plan both decrease modes run: `ROUTE_SWAP` sells collateral for debt
    ///         delivered to the account, `ASSERT_ACCOUNT_BALANCE` proves the delivery, `ACCOUNT_REPAY`
    ///         and `ACCOUNT_WITHDRAW_COLLATERAL` move the position, `SETTLE` pays the swap from the
    ///         router, and `ASSERT_HEALTH` checks the result.
    /// @param params The decrease parameters; the route and the input cap come from here.
    /// @param account The caller's MarginAccount.
    /// @param requiredDelivery The debt the route must deliver on top of what the account already holds.
    /// @param repayAmount The `ACCOUNT_REPAY` amount; `type(uint256).max` repays all.
    /// @param withdrawAmount The `ACCOUNT_WITHDRAW_COLLATERAL` amount, delivered to the router;
    ///        `OPEN_DELTA` withdraws exactly what the swap consumed.
    /// @param healthBound The `ASSERT_HEALTH` bound; zero skips the check.
    /// @return actions The packed opcode string.
    /// @return actionParams The encoded parameters, one per opcode.
    function _decreasePlan(
        DecreaseParams calldata params,
        address account,
        uint256 requiredDelivery,
        uint256 repayAmount,
        uint256 withdrawAmount,
        Ltv healthBound
    ) private view returns (bytes memory actions, bytes[] memory actionParams) {
        actions = abi.encodePacked(
            uint8(MarginActions.ROUTE_SWAP),
            uint8(MarginActions.ASSERT_ACCOUNT_BALANCE),
            uint8(MarginActions.ACCOUNT_REPAY),
            uint8(MarginActions.ACCOUNT_WITHDRAW_COLLATERAL),
            uint8(Actions.SETTLE),
            uint8(MarginActions.ASSERT_HEALTH)
        );
        actionParams = new bytes[](6);
        // ROUTE_SWAP (universalRouter, input, maxIn, commands, inputs)
        // Flash-take up to maxCollateralIn of collateral and run the caller's route, which buys the
        // debt exact-output into the account. The unspent take is settled back, so the router then
        // owes the pool exactly what the swap consumed.
        actionParams[0] = abi.encode(
            params.universalRouter,
            params.market.collateral,
            uint256(params.maxCollateralIn),
            params.routeCommands,
            params.routeInputs
        );
        // ASSERT_ACCOUNT_BALANCE (currency, minAmount)
        // The floor is what the account held going into the unlock plus the required delivery, so
        // the absolute check enforces the swap delta and a pre-existing or donated balance cannot
        // mask a short fill.
        actionParams[1] = abi.encode(params.market.debt, params.market.debt.balanceOf(account) + requiredDelivery);
        // ACCOUNT_REPAY (adapter, market, amount)
        // type(uint256).max repays all, resolved by the adapter in the venue's own terms (see
        // ILendingAdapter.encodeRepay).
        actionParams[2] = abi.encode(params.adapter, params.market, repayAmount);
        // ACCOUNT_WITHDRAW_COLLATERAL (adapter, market, amount, to)
        // To the router, which pays the swap from it. OPEN_DELTA resolves to the router's remaining
        // collateral debt to the pool, which is what the swap consumed.
        actionParams[3] = abi.encode(params.adapter, params.market, withdrawAmount, address(this));
        // SETTLE (currency, amount, payerIsUser)
        // Pay the swap's collateral from the router's own balance.
        actionParams[4] = abi.encode(params.market.collateral, uint256(ActionConstants.OPEN_DELTA), false);
        // ASSERT_HEALTH (adapter, market, maxLtv)
        // A zero bound skips the check.
        actionParams[5] = abi.encode(params.adapter, params.market, healthBound);
    }

    /// @notice Sends the caller the collateral the router gained across a decrease unlock and returns
    ///         it: the realized PnL on a close, normally zero on a partial decrease.
    /// @param collateral The market's collateral currency.
    /// @param balanceBefore The router's collateral balance before the unlock.
    /// @return residual The amount returned to the caller.
    function _returnCollateralGain(Currency collateral, uint256 balanceBefore) private returns (uint256 residual) {
        residual = collateral.balanceOfSelf() - balanceBefore;
        if (residual > 0) collateral.transfer(msgSender(), residual);
    }

    /// @inheritdoc IMarginRouter
    function addCollateral(AddCollateralParams calldata params)
        external
        payable
        isNotLocked
        checkDeadline(params.deadline)
        returns (address account)
    {
        account = createAccount(msgSender(), params.subId);

        uint256 amount;
        if (msg.value > 0) {
            // native collateral: wrap to WETH and credit the account
            _requireWeth9();
            if (Currency.unwrap(params.market.collateral) != address(WETH9)) revert NativeCollateralMismatch();
            amount = msg.value;
            _wrap(msg.value);
            Currency.wrap(address(WETH9)).transfer(account, msg.value);
        } else {
            if (params.amount == 0) revert ZeroAmount();
            amount = params.amount;
            permit2.transferFrom(
                msgSender(), account, params.amount.toUint160(), Currency.unwrap(params.market.collateral)
            );
        }
        // the router is the account manager, so it can supply directly without an unlock
        IMarginAccount(account).supplyCollateral(params.adapter, params.market, amount);
        // best-effort events: no unlock ran, so the PositionUpdated snapshot and CollateralAdded both
        // come from this one venue read, which can revert (oracle downtime, even on a debt-free Morpho
        // position). The supply has already completed, so emit both on success and skip both on
        // failure rather than roll it back.
        (bool read, PositionData memory position) = _readPosition(params.adapter, params.market, account);
        if (read) {
            _emitPosition(params.market, account, position);
            emit CollateralAdded(
                msgSender(),
                account,
                params.market.collateral,
                amount,
                position.collateralAmount,
                position.debtAmount,
                position.currentLtv,
                position.healthFactorWad
            );
        }
    }

    /// @inheritdoc IMarginRouter
    function execute(bytes calldata unlockData, uint256 deadline) external payable isNotLocked checkDeadline(deadline) {
        _executeActions(unlockData);
        // clear the active account so it cannot leak into a later multicall leg within the same
        // transaction (transient storage persists for the whole tx, not per external call). The
        // NoActiveAccount guard is the backstop, and any residual value is scoped to this locker's
        // own account regardless, so this is defense in depth.
        TransientPlanState.setActiveAccount(address(0));
    }

    /// @inheritdoc IMarginRouter
    /// @dev Resolves the inherited MarginAccountFactory implementation; the manager baked into the
    ///      predicted address is this router.
    function accountOf(address owner, uint256 subId)
        public
        view
        override(IMarginRouter, MarginAccountFactory)
        returns (address)
    {
        return super.accountOf(owner, subId);
    }

    /// @inheritdoc IMarginRouter
    /// @dev Resolves the inherited MarginAccountFactory implementation; the manager baked into every
    ///      account is this router.
    function createAccount(address owner, uint256 subId)
        public
        override(IMarginRouter, MarginAccountFactory)
        returns (address)
    {
        return super.createAccount(owner, subId);
    }

    /// @notice The authenticated caller for the current lock. Overrides `BaseActionsRouter.msgSender`
    ///         to return the address stored by `ReentrancyLock._getLocker`, which is set to
    ///         `msg.sender` at the start of each `isNotLocked` call. The active account is derived
    ///         from this value, so correctness here is load-bearing for the entire position system.
    /// @return The authenticated caller (the locker set by `ReentrancyLock`) for the current unlock.
    function msgSender() public view override returns (address) {
        return _getLocker();
    }

    /// @notice Shared implementation for `increasePosition`. Deploys the account if needed, pulls
    ///         optional equity, then builds and runs the flash-style unlock: swap debt to collateral
    ///         (exact-output), supply the collateral, borrow the debt owed, and settle the swap.
    ///         Increasing an account that already holds a position simply adds leverage to it; the
    ///         first increase opens the position.
    /// @param params The increase parameters; see `IncreaseParams`.
    /// @return account The caller's MarginAccount address.
    /// @return debtBefore The account's debt before the increase; the caller derives debtDrawn as the
    ///         post-increase debt minus this, correct for both a fresh open and an increase.
    function _increase(IncreaseParams calldata params) private returns (address account, uint256 debtBefore) {
        // a zero buy would feed the exact-output swap a zero, which the PoolManager rejects
        if (params.collateralToBuy == 0) revert ZeroAmount();
        if (params.maxDebtIn == 0) revert SlippageBoundRequired();
        // the health bound is optional here (zero skips it), but a supplied one must be able to bind:
        // at or above 100% it can never be exceeded and would silently disable ASSERT_HEALTH
        if (Ltv.unwrap(params.maxLtvAfter) != 0 && Ltv.unwrap(params.maxLtvAfter) >= Units.WAD) {
            revert IneffectiveLtvBound(params.maxLtvAfter);
        }

        account = createAccount(msgSender(), params.subId);

        // snapshot debt before drawing leverage so debtDrawn is correct whether this opens a fresh
        // position or increases an existing one
        (, debtBefore) = params.adapter.positionOf(account, params.market);

        // provide equity: native ETH (wrapped to WETH) when sent, else ERC20 pulled via Permit2
        if (msg.value > 0) {
            _requireWeth9();
            if (Currency.unwrap(params.market.collateral) != address(WETH9)) revert NativeCollateralMismatch();
            _wrap(msg.value);
            Currency.wrap(address(WETH9)).transfer(account, msg.value);
        } else if (params.equity > 0) {
            permit2.transferFrom(
                msgSender(), account, params.equity.toUint160(), Currency.unwrap(params.market.collateral)
            );
        }

        bytes memory actions = abi.encodePacked(
            uint8(MarginActions.ROUTE_SWAP),
            uint8(MarginActions.ASSERT_ACCOUNT_BALANCE),
            uint8(MarginActions.ACCOUNT_SUPPLY_COLLATERAL),
            uint8(MarginActions.ACCOUNT_BORROW),
            uint8(Actions.SETTLE),
            uint8(MarginActions.ASSERT_HEALTH)
        );
        bytes[] memory actionParams = new bytes[](6);
        // ROUTE_SWAP (universalRouter, input, maxIn, commands, inputs)
        // Flash-take up to maxDebtIn of debt and run the caller's route, which buys collateralToBuy
        // exact-output into the account. The unspent take is settled back, so the router then owes
        // the pool exactly what the swap consumed.
        actionParams[0] = abi.encode(
            params.universalRouter,
            params.market.debt,
            uint256(params.maxDebtIn),
            params.routeCommands,
            params.routeInputs
        );
        // ASSERT_ACCOUNT_BALANCE (currency, minAmount)
        // The floor is what the account held going into the unlock (the equity just transferred in,
        // plus anything idle) plus collateralToBuy, so the absolute check enforces the swap delta and
        // a pre-existing or donated balance cannot mask a short fill.
        uint256 collateralHeldBefore = params.market.collateral.balanceOf(account);
        actionParams[1] = abi.encode(params.market.collateral, collateralHeldBefore + params.collateralToBuy);
        // ACCOUNT_SUPPLY_COLLATERAL (adapter, market, amount)
        // OPEN_DELTA supplies the account's whole collateral balance: equity plus the bought amount.
        actionParams[2] = abi.encode(params.adapter, params.market, uint256(ActionConstants.OPEN_DELTA));
        // ACCOUNT_BORROW (adapter, market, amount, to)
        // To the router; OPEN_DELTA borrows the router's remaining debt to the pool, which is what the
        // swap consumed.
        actionParams[3] = abi.encode(params.adapter, params.market, uint256(ActionConstants.OPEN_DELTA), address(this));
        // SETTLE (currency, amount, payerIsUser)
        // Pay the swap's debt from the router's own balance.
        actionParams[4] = abi.encode(params.market.debt, uint256(ActionConstants.OPEN_DELTA), false);
        // ASSERT_HEALTH (adapter, market, maxLtv)
        // A zero bound skips the check, so callers relying on maxDebtIn alone are unaffected.
        actionParams[5] = abi.encode(params.adapter, params.market, params.maxLtvAfter);

        _unlockAs(account, actions, actionParams);
    }

    /// @notice Runs a plan inside one PoolManager unlock with `account` bound as the active account
    ///         for its account-scoped actions, then clears the binding so it cannot leak into a later
    ///         call in the same transaction.
    /// @param account The caller's MarginAccount the plan operates on.
    /// @param actions The packed opcode string.
    /// @param actionParams The encoded parameters, one per opcode.
    function _unlockAs(address account, bytes memory actions, bytes[] memory actionParams) private {
        TransientPlanState.setActiveAccount(account);
        poolManager.unlock(abi.encode(actions, actionParams));
        TransientPlanState.setActiveAccount(address(0));
    }

    /// @notice Dispatches one action from the current plan to its handler. Called by
    ///         `BaseActionsRouter._executeActions` for each action.
    /// @dev Overrides `V4Router._handleAction`. Margin opcodes are matched one by one, never by
    ///      range. `SET_ACCOUNT` and `ROUTE_SWAP` act on the router itself and need no active
    ///      account. The account-scoped opcodes (`MarginActions.isAccountScoped`) need one, which is
    ///      always derived from the authenticated caller and read from transient storage, never from
    ///      action params. Everything else is a core v4 opcode (`_handleCoreAction`), so an undefined
    ///      opcode reverts `UnsupportedAction` whether or not the plan bound an account.
    /// @param action The opcode from `MarginActions` or the inherited `Actions` library.
    /// @param params ABI-encoded parameters for the action; decoded by `MarginCalldataDecoder`
    ///        (margin opcodes) or `CalldataDecoder` (the intercepted core opcodes).
    function _handleAction(uint256 action, bytes calldata params) internal override {
        if (action == MarginActions.SET_ACCOUNT) {
            // account derived from the authenticated caller and this subId, never from calldata;
            // createAccount is idempotent, so re-selecting a live sub-account just re-binds it
            TransientPlanState.setActiveAccount(createAccount(msgSender(), params.decodeSubId()));
        } else if (action == MarginActions.ROUTE_SWAP) {
            _routeSwap(params);
        } else if (MarginActions.isAccountScoped(action)) {
            // needs a preceding SET_ACCOUNT; the fixed entry points bind the account before the
            // unlock, so only a hand-built plan can reach this revert
            address account = TransientPlanState.activeAccount();
            if (account == address(0)) revert NoActiveAccount();
            _handleAccountAction(action, params, account);
        } else {
            _handleCoreAction(action, params);
        }
    }

    /// @notice Reverts `NativeNotSupported` on a router deployed without a WETH9. Guards every path
    ///         that converts between native value and the wrapped token, so a chain whose native
    ///         token has no 1:1 wrapper (or whose ERC-20 view of it uses different decimals) never
    ///         reaches a wrap. ERC-20 flows are unaffected.
    function _requireWeth9() private view {
        if (address(WETH9) == address(0)) revert NativeNotSupported();
    }

    /// @notice Handles a core v4 opcode. `SWEEP`/`WRAP`/`UNWRAP` are intercepted here with
    ///         PositionManager-identical semantics because V4Router does not handle them; every
    ///         other opcode goes to V4Router, which reverts `UnsupportedAction` for one it does not
    ///         define.
    function _handleCoreAction(uint256 action, bytes calldata params) private {
        if (action == Actions.SWEEP) {
            (Currency currency, address to) = params.decodeCurrencyAndAddress();
            _sweep(currency, _mapRecipient(to));
        } else if (action == Actions.WRAP) {
            _requireWeth9();
            _wrap(
                _mapWrapUnwrapAmount(
                    CurrencyLibrary.ADDRESS_ZERO, params.decodeUint256(), Currency.wrap(address(WETH9))
                )
            );
        } else if (action == Actions.UNWRAP) {
            _requireWeth9();
            _unwrap(
                _mapWrapUnwrapAmount(
                    Currency.wrap(address(WETH9)), params.decodeUint256(), CurrencyLibrary.ADDRESS_ZERO
                )
            );
        } else {
            super._handleAction(action, params);
        }
    }

    /// @notice Runs the `ROUTE_SWAP` action: route a swap through the Universal Router (v2/v3/v4)
    ///         behind a flash-take of the input. Because UR self-settles its own swap, wrapping the
    ///         call in a flash-take/settle envelope leaves the router owing exactly what UR spent, the
    ///         same negative delta a native v4 exact-output swap would leave, which a downstream
    ///         `ACCOUNT_BORROW`/`SETTLE` then nets via `OPEN_DELTA`. Operates only on the router; the
    ///         caller's route delivers the output to the account bound by `SET_ACCOUNT`.
    /// @param params ABI-encoded `(universalRouter, input, maxIn, commands, inputs)`. The Universal
    ///        Router is supplied per call (not a router immutable) so callers pick the UR deployment
    ///        their route targets; it must be non-zero and carry already-unlocked `V4_SWAP` support.
    function _routeSwap(bytes calldata params) private {
        (address universalRouter, Currency input, uint256 maxIn, bytes memory commands, bytes[] memory inputs) =
            params.decodeRouteSwap();
        if (universalRouter == address(0)) revert UniversalRouterNotSet();
        address token = Currency.unwrap(input);

        // snapshot any balance the router already holds in the input currency, so step 4 settles only
        // THIS call's unspent flash-take and never a pre-existing balance. Anyone can inflate that
        // balance with a plain transfer to the router; folding it into the settle would flip the
        // router's delta positive (reverting the curated flow) or silently subsidize the position. The
        // pre-existing balance is left untouched, recoverable through the SWEEP action.
        uint256 balanceBeforeTake = input.balanceOfSelf();

        // 1. flash-borrow up to `maxIn` of the input from the PoolManager; the router now owes it
        _take(input, address(this), maxIn);

        // 2. fund the Universal Router to pull exactly what it spends, via a Permit2 allowance scoped
        //    to this call (approve the token to Permit2 once, lazily)
        if (IERC20(token).allowance(address(this), address(permit2)) < maxIn) {
            IERC20(token).forceApprove(address(permit2), type(uint256).max);
        }
        permit2.approve(token, universalRouter, maxIn.toUint160(), uint48(block.timestamp));

        // 3. run the caller-built route inside this existing unlock (already-unlocked V4_SWAP support);
        //    it delivers the output to the active account and self-settles its own swap
        IUniversalRouter(universalRouter).execute(commands, inputs, block.timestamp);

        // 4. settle only the unspent portion of this call's flash-take (current balance minus what the
        //    router held before the take), so its remaining input debt equals exactly what UR spent and
        //    a donated/residual balance can neither flip the delta positive nor subsidize the position
        uint256 balanceAfter = input.balanceOfSelf();
        uint256 leftover = balanceAfter > balanceBeforeTake ? balanceAfter - balanceBeforeTake : 0;
        if (leftover > 0) _settle(input, address(this), leftover);

        // 5. clear the scoped Permit2 allowance to the caller-supplied Universal Router. Permit2 spends
        //    while block.timestamp <= expiration, so a non-zero residual would stay live for the rest
        //    of the block; zeroing it leaves no spendable allowance to an unvalidated address past this
        //    call.
        permit2.approve(token, universalRouter, 0, 0);
    }

    /// @notice Dispatches an account-scoped margin opcode to its handler. Every action takes a
    ///         caller-chosen adapter; a hostile one reaches only the caller's own account (see
    ///         `MarginAccount`), so no action is gated on who the adapter is.
    /// @param action The account-scoped opcode.
    /// @param params ABI-encoded parameters for the action.
    /// @param account The active account (non-zero; the caller checked the guard).
    function _handleAccountAction(uint256 action, bytes calldata params, address account) private {
        if (action == MarginActions.ACCOUNT_SUPPLY_COLLATERAL) _supplyCollateral(params, account);
        else if (action == MarginActions.ACCOUNT_WITHDRAW_COLLATERAL) _withdrawCollateral(params, account);
        else if (action == MarginActions.ACCOUNT_BORROW) _borrow(params, account);
        else if (action == MarginActions.ACCOUNT_REPAY) _repay(params, account);
        else if (action == MarginActions.ACCOUNT_SWEEP) _accountSweep(params, account);
        else if (action == MarginActions.ASSERT_ACCOUNT_BALANCE) _assertAccountBalance(params, account);
        else if (action == MarginActions.ASSERT_HEALTH) _assertHealth(params, account);
        else if (action == MarginActions.PULL_TO_ACCOUNT) _pullToAccount(params, account);
        else revert UnsupportedAction(action);
    }

    /// @notice Supplies collateral to the lending protocol on the account's behalf. `OPEN_DELTA`
    ///         supplies the account's full collateral balance (equity plus what the swap bought).
    function _supplyCollateral(bytes calldata params, address account) private {
        (ILendingAdapter adapter, Market memory market, uint256 amount) = params.decodeAdapterMarketAmount();
        if (amount == ActionConstants.OPEN_DELTA) amount = market.collateral.balanceOf(account);
        IMarginAccount(account).supplyCollateral(adapter, market, amount);
        (bool read, PositionData memory position) = _readPosition(adapter, market, account);
        if (read) _emitPosition(market, account, position);
    }

    /// @notice Borrows debt to `to`. `OPEN_DELTA` borrows exactly the debt the swap owes the pool.
    function _borrow(bytes calldata params, address account) private {
        (ILendingAdapter adapter, Market memory market, uint256 amount, address to) =
            params.decodeAdapterMarketAmountReceiver();
        if (amount == ActionConstants.OPEN_DELTA) amount = _getFullDebt(market.debt);
        IMarginAccount(account).borrow(adapter, market, amount, to);
        (bool read, PositionData memory position) = _readPosition(adapter, market, account);
        if (read) _emitPosition(market, account, position);
    }

    /// @notice Withdraws collateral to `to`. `OPEN_DELTA` withdraws exactly the collateral the swap
    ///         owes the pool (partial delever); a full close passes the explicit full collateral amount.
    function _withdrawCollateral(bytes calldata params, address account) private {
        (ILendingAdapter adapter, Market memory market, uint256 amount, address to) =
            params.decodeAdapterMarketAmountReceiver();
        if (amount == ActionConstants.OPEN_DELTA) amount = _getFullDebt(market.collateral);
        IMarginAccount(account).withdrawCollateral(adapter, market, amount, to);
        (bool read, PositionData memory position) = _readPosition(adapter, market, account);
        if (read) _emitPosition(market, account, position);
    }

    /// @notice Repays debt to the lending protocol. `type(uint256).max` repays the full debt,
    ///         resolved by the adapter in the venue's own terms (see `ILendingAdapter.encodeRepay`).
    function _repay(bytes calldata params, address account) private {
        (ILendingAdapter adapter, Market memory market, uint256 amount) = params.decodeAdapterMarketAmount();
        uint256 repaid = IMarginAccount(account).repay(adapter, market, amount);
        // recorded for the partial decrease, which checks after the unlock that a repay actually
        // happened; execute plans never read it
        TransientPlanState.setLastRepaid(repaid);
        (bool read, PositionData memory position) = _readPosition(adapter, market, account);
        if (read) _emitPosition(market, account, position);
    }

    /// @notice Reads the account's position snapshot for `market` via the adapter, swallowing a revert.
    /// @dev Best-effort: `describePosition` reverts for a market the venue no longer has, but withdraw
    ///      and repay are intentionally never market-gated (a position must always be exitable), so a
    ///      failing read is swallowed rather than reverting the action. `describePosition` is `view`, so
    ///      the call is a STATICCALL and a hostile adapter can neither reenter nor mutate state through
    ///      it.
    /// @return read True if the venue read succeeded.
    /// @return position The snapshot read; zeroed when `read` is false.
    function _readPosition(ILendingAdapter adapter, Market memory market, address account)
        private
        view
        returns (bool read, PositionData memory position)
    {
        try adapter.describePosition(account, market) returns (PositionData memory current) {
            return (true, current);
        } catch {}
    }

    /// @notice Emits a `PositionUpdated` snapshot for the account's market, so an `execute` plan is as
    ///         observable as the curated entry points. Called after every supply, withdraw, borrow, and
    ///         repay dispatched through the unlock, by the zero-debt swap-free close, and by
    ///         `addCollateral`, which reuses the `_readPosition` read for its `CollateralAdded`.
    /// @dev Pure event-emission helper (no external call), mirroring `_emitClosed`: callers resolve the
    ///      snapshot via `_readPosition` first and skip the emit when that read failed.
    function _emitPosition(Market memory market, address account, PositionData memory position) private {
        emit PositionUpdated(
            msgSender(),
            account,
            market.collateral,
            market.debt,
            market.data,
            position.collateralAmount,
            position.debtAmount,
            position.currentLtv,
            position.maxLtv,
            position.healthFactorWad
        );
    }

    /// @notice Emits the `PositionDecreased` for a full close, whose resulting state is a known empty
    ///         position (zero collateral, zero debt, zero LTV, unbounded health) and so needs no venue
    ///         read. Shared by the swap-free zero-debt close and the swap-based full close so the
    ///         event is encoded in one place.
    /// @param params The decrease parameters (the market key is read from them).
    /// @param account The closed MarginAccount.
    /// @param debtRepaid The debt the close repaid (zero for the swap-free path).
    /// @param collateralWithdrawn All collateral the position held before the close.
    /// @param collateralReturned The collateral delivered to the caller.
    function _emitClosed(
        DecreaseParams calldata params,
        address account,
        uint256 debtRepaid,
        uint256 collateralWithdrawn,
        uint256 collateralReturned
    ) private {
        emit PositionDecreased(
            msgSender(),
            account,
            params.market.collateral,
            params.market.debt,
            params.market.data,
            debtRepaid,
            collateralWithdrawn,
            collateralReturned,
            0,
            0,
            Ltv.wrap(0),
            type(uint256).max
        );
    }

    /// @notice Sweeps a token from the account to `to` (owner/manager only, enforced by the account).
    function _accountSweep(bytes calldata params, address account) private {
        (Currency currency, uint256 amount, address to) = params.decodeSweep();
        IMarginAccount(account).sweep(currency, amount, to);
    }

    /// @notice Routed-swap fill guarantee: require the account's resulting balance of `currency` is at
    ///         least `minAmount`, reverting `IncompleteFill` otherwise. This is an absolute-balance
    ///         check by contract (so it composes predictably in `execute` plans); the curated flows
    ///         achieve a swap-DELTA guarantee by setting `minAmount` to the account's pre-unlock
    ///         balance plus the amount the route was asked to deliver, so a pre-existing balance cannot
    ///         mask a short fill.
    function _assertAccountBalance(bytes calldata params, address account) private view {
        (Currency currency, uint256 minAmount) = params.decodeFillCheck();
        uint256 held = currency.balanceOf(account);
        if (held < minAmount) revert IncompleteFill(minAmount, held);
    }

    /// @notice Asserts the position's current LTV does not exceed `maxLtv`; a zero bound skips the check.
    function _assertHealth(bytes calldata params, address account) private view {
        (ILendingAdapter adapter, Market memory market, Ltv maxLtv) = params.decodeHealthCheck();
        if (Ltv.unwrap(maxLtv) != 0 && adapter.currentLtvWad(account, market).gt(maxLtv)) revert PositionUnhealthy();
    }

    /// @notice Moves a token into the account: pulled from the caller via Permit2 (`payerIsUser`) or
    ///         from the router's own balance. Unlike the pool-delta opcodes, `0` is not an `OPEN_DELTA`
    ///         full-balance sentinel here: a pull with no amount is a plan-builder error, rejected
    ///         loudly. `CONTRACT_BALANCE` is honored only on the router-balance path.
    function _pullToAccount(bytes calldata params, address account) private {
        (Currency currency, uint256 amount, bool payerIsUser) = params.decodePull();
        if (amount == 0) revert ZeroAmount();
        if (payerIsUser) {
            // CONTRACT_BALANCE means the router's own balance and must not be charged to the caller;
            // no explicit check is needed because the sentinel (1 << 255) does not fit the uint160
            // cast, which reverts
            permit2.transferFrom(msgSender(), account, amount.toUint160(), Currency.unwrap(currency));
        } else {
            if (amount == ActionConstants.CONTRACT_BALANCE) amount = currency.balanceOfSelf();
            currency.transfer(account, amount);
        }
    }

    /// @notice Sweeps the router's entire balance of `currency` (native included) to `to`.
    /// @dev The plan-builder's tool for netting the router to zero at the end of an `execute` plan.
    ///      Identical to PositionManager's sweep semantics.
    /// @param currency The token to sweep.
    /// @param to The recipient (already resolved through `_mapRecipient`).
    function _sweep(Currency currency, address to) private {
        uint256 balance = currency.balanceOfSelf();
        if (balance > 0) currency.transfer(to, balance);
    }

    /// @notice Pays the PoolManager. When the payer is this router, transfers directly; any other
    ///         payer pays through Permit2. Mirrors the two-payer settle pattern used by
    ///         PositionManager.
    /// @dev Overrides `DeltaResolver._pay`, called during the `SETTLE` action to clear the
    ///      router's debt to the PoolManager.
    /// @param currency The token to transfer.
    /// @param payer The address bearing the payment. `address(this)` means the router holds the
    ///        tokens (e.g. after borrowing debt from the account); any other address is an EOA or
    ///        contract paying via Permit2.
    /// @param amount The amount to transfer, in the token's native decimals.
    function _pay(Currency currency, address payer, uint256 amount) internal override {
        if (payer == address(this)) {
            currency.transfer(address(poolManager), amount);
        } else {
            permit2.transferFrom(payer, address(poolManager), amount.toUint160(), Currency.unwrap(currency));
        }
    }
}
