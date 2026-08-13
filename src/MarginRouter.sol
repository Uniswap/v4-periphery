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
import {Market} from "./types/Market.sol";
import {Ltv} from "./types/Ltv.sol";
import {PositionData} from "./types/PositionData.sol";
import {Owner} from "./types/Owner.sol";

/// @title MarginRouter
/// @author Uniswap Labs
/// @notice The entry point for the margin-trading suite. Composes the v4 action machinery and
///         builds each leveraged position as a single flash-style swap inside one PoolManager
///         unlock: borrow the debt, swap it into collateral, supply the collateral, then draw the
///         debt back to settle. Each operation runs against the caller's own MarginAccount, derived
///         from the authenticated caller (never from a caller-supplied address). The router is the
///         manager of every account it deploys, so it can drive their lending primitives.
///
///         Supported markets are restricted to the governance allowlist of lending adapters, which
///         curate standard ERC-20 markets only (no fee-on-transfer or rebasing tokens). Under that
///         constraint every curated flow (`increasePosition`/`decreasePosition`/`addCollateral`)
///         nets to zero with no router residual by construction.
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

    // transient slot holding the account for the current unlock, set from the authenticated caller
    bytes32 private constant ACTIVE_ACCOUNT_SLOT = keccak256("uniswap.marginRouter.activeAccount");

    // 1e18 == 100% LTV. A resulting-health bound at or above this can never be exceeded by a real LTV,
    // so passing one (e.g. type(uint256).max, the codebase's "no limit" sentinel elsewhere) would
    // satisfy a "bound is set" check yet leave ASSERT_HEALTH a no-op; a supplied bound must sit below it.
    uint256 private constant WAD = 1e18;

    Owner internal _governance;
    mapping(ILendingAdapter adapter => bool isAllowed) internal _allowedAdapters;

    /// @notice Emitted when governance allows or disallows a lending adapter.
    /// @param adapter The adapter address whose allowlist status changed.
    /// @param allowed True if the adapter was allowed; false if it was disallowed.
    event AdapterAllowed(address indexed adapter, bool allowed);

    /// @notice Emitted when the current governance proposes a successor for the two-step handoff.
    /// @param currentGovernance The governance address that proposed the successor.
    /// @param pendingGovernance The address proposed as the next governance.
    event GovernanceTransferStarted(address indexed currentGovernance, address indexed pendingGovernance);

    /// @notice Emitted when a proposed successor accepts governance and the handoff completes.
    /// @param previousGovernance The governance address that was replaced.
    /// @param newGovernance The address that became the new governance.
    event GovernanceTransferred(address indexed previousGovernance, address indexed newGovernance);

    /// @dev Reverts `DeadlinePassed` if `block.timestamp` has passed `deadline`.
    modifier checkDeadline(uint256 deadline) {
        if (block.timestamp > deadline) revert DeadlinePassed(deadline);
        _;
    }

    /// @notice Deploys the margin router.
    /// @param poolManager_ The v4 PoolManager singleton the router unlocks for every position flow.
    /// @param permit2_ The Permit2 contract used to pull caller equity and settle swaps.
    /// @param weth9_ The canonical WETH9 contract used to wrap native token equity.
    /// @param accountImplementation The MarginAccount implementation cloned for each account.
    /// @param governance_ The initial governance address (e.g. the deployer, a multisig, or a
    ///        timelock) that curates the adapter allowlist. Passed explicitly rather than read from
    ///        `msg.sender` so a deterministic CREATE2 deployment sets the intended owner instead of
    ///        the CREATE2 factory. Mirrors v4-core's `PoolManager(address initialOwner)` pattern.
    constructor(
        IPoolManager poolManager_,
        IAllowanceTransfer permit2_,
        IWETH9 weth9_,
        address accountImplementation,
        address governance_
    )
        V4Router(poolManager_)
        Permit2Forwarder(permit2_)
        NativeWrapper(weth9_)
        MarginAccountFactory(accountImplementation)
    {
        // governance is set explicitly so CREATE2 deployment names the intended owner, not the
        // CREATE2 factory; hand off to a timelock or multisig after setup
        _governance.write(governance_);
    }

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
        // one post-increase snapshot carries full resulting state (indexers need no extra RPC) and
        // also yields debtDrawn, so no separate post-unlock position read is needed
        PositionData memory position = params.adapter.describePosition(account, params.market);
        emit PositionIncreased(
            msgSender(),
            account,
            params.market.collateral,
            params.market.debt,
            msg.value > 0 ? msg.value : params.equity,
            params.collateralToBuy,
            position.debtAmount - debtBefore,
            position.collateralAmount,
            position.debtAmount,
            position.currentLtv,
            position.maxLtv,
            position.healthFactorWad
        );
    }

    /// @inheritdoc IMarginRouter
    /// @dev A partial decrease (`debtToRepay < type(uint256).max`) and a full close
    ///      (`debtToRepay == type(uint256).max`) share one implementation: route the caller's swap to
    ///      buy the target debt (delivered to the account), assert it arrived, repay, withdraw
    ///      collateral, and settle the swap from the router. The caller's route sizes the swap; only
    ///      four plan amounts vary by `fullClose`: the fill-assert threshold, the repay amount, how
    ///      much collateral is withdrawn, and the health bound. Everything else, including the residual
    ///      measure-and-forward, is identical: a partial decrease withdraws exactly the swap cost so its
    ///      residual is zero, while a full close withdraws everything and returns the realized PnL (plus
    ///      any debt the route over-bought, swept back after the unlock).
    function decreasePosition(DecreaseParams calldata params)
        external
        isNotLocked
        checkDeadline(params.deadline)
        returns (address account)
    {
        bool fullClose = params.debtToRepay == type(uint256).max;

        // a partial decrease's bounds don't depend on the position, so validate them before any
        // external read: a non-zero repay (a zero would feed a zero into the exact-output swap, which
        // the PoolManager rejects) and a resulting-health bound so it cannot worsen the LTV
        if (!fullClose) {
            if (params.debtToRepay == 0) revert ZeroAmount();
            if (Ltv.unwrap(params.maxLtvAfter) == 0) revert SlippageBoundRequired();
            // reject a bound that cannot bind (>= 100%): it satisfies the require above yet leaves
            // ASSERT_HEALTH a no-op, so the "mandatory" partial-decrease health bound stays real
            if (Ltv.unwrap(params.maxLtvAfter) >= WAD) revert IneffectiveLtvBound(params.maxLtvAfter);
        }

        account = accountOf(msgSender(), params.subId);
        (uint256 collateralBefore, uint256 debt) = params.adapter.positionOf(account, params.market);

        // a full close of a debt-free position (funded only via addCollateral, repaid out of band, or
        // fully liquidated) needs no swap: withdraw the collateral straight to the caller and finish.
        if (fullClose && debt == 0) {
            if (collateralBefore > 0) {
                IMarginAccount(account).withdrawCollateral(params.adapter, params.market, collateralBefore, msgSender());
            }
            // this path bypasses the unlock interpreter, so no action handler fires the snapshot;
            // emit the terminal PositionUpdated here so snapshot-only consumers see the close
            _emitPosition(params.adapter, params.market, account);
            // all collateral withdrawn straight to the caller; nothing left in the position
            emit PositionDecreased(
                msgSender(),
                account,
                params.market.collateral,
                params.market.debt,
                0,
                collateralBefore,
                collateralBefore,
                0,
                0,
                Ltv.wrap(0),
                type(uint256).max
            );
            return account;
        }

        // a swap runs from here (the debt-free full close returned above), so the input cap is mandatory
        if (params.maxCollateralIn == 0) revert SlippageBoundRequired();

        _setActiveAccount(account);

        bytes memory actions = abi.encodePacked(
            uint8(MarginActions.ROUTE_SWAP),
            uint8(MarginActions.ASSERT_ACCOUNT_BALANCE),
            uint8(MarginActions.ACCOUNT_REPAY),
            uint8(MarginActions.ACCOUNT_WITHDRAW_COLLATERAL),
            uint8(Actions.SETTLE),
            uint8(MarginActions.ASSERT_HEALTH)
        );
        // the mode-dependent amounts are inlined (kept out of locals to stay under the stack limit).
        // full close: require the route delivered AT LEAST the current debt (asserted below), repay
        // ALL by shares so the borrow clears with no borrow-share dust, withdraw all collateral, and
        // pass a zero health bound that ASSERT_HEALTH skips; any debt the route over-bought is swept
        // back after the unlock. A partial requires and repays exactly `debtToRepay`, withdraws only
        // the collateral the swap consumed (OPEN_DELTA == the router's remaining collateral debt), and
        // enforces `maxLtvAfter`.
        bytes[] memory actionParams = new bytes[](6);
        // route the collateral->debt swap through the Universal Router with the caller-supplied route,
        // behind a flash-take of up to maxCollateralIn collateral; the route buys the target debt
        // exact-output and delivers it to the account, and ROUTE_SWAP settles the unspent take so the
        // router's remaining collateral debt equals what the swap spent
        actionParams[0] = abi.encode(
            params.universalRouter,
            params.market.collateral,
            uint256(params.maxCollateralIn),
            params.routeCommands,
            params.routeInputs
        );
        // require the route to deliver the debt the repay needs ON TOP of any debt-token balance the
        // account already holds going into the unlock. Setting the ASSERT_ACCOUNT_BALANCE threshold to
        // `balance + required` makes the absolute check enforce the SWAP DELTA, so a pre-existing or
        // donated balance cannot mask an exact-output under-fill (audit M-03)
        uint256 debtHeldBefore = params.market.debt.balanceOf(account);
        actionParams[1] = abi.encode(params.market.debt, debtHeldBefore + (fullClose ? debt : params.debtToRepay));
        actionParams[2] = abi.encode(params.adapter, params.market, fullClose ? type(uint256).max : params.debtToRepay);
        actionParams[3] = abi.encode(
            params.adapter,
            params.market,
            fullClose ? collateralBefore : uint256(ActionConstants.OPEN_DELTA),
            address(this)
        );
        actionParams[4] = abi.encode(params.market.collateral, uint256(ActionConstants.OPEN_DELTA), false);
        actionParams[5] = abi.encode(params.adapter, params.market, fullClose ? Ltv.wrap(0) : params.maxLtvAfter);

        // measure the router's own collateral gain across the unlock: zero for a partial decrease (it
        // withdraws exactly the swap cost), the realized PnL for a full close
        uint256 balanceBefore = params.market.collateral.balanceOfSelf();
        poolManager.unlock(abi.encode(actions, actionParams));
        _setActiveAccount(address(0));

        // a full close whose route over-bought the debt (buffered for accrual) leaves the excess in the
        // account after repay-all; return it to the caller so nothing is stranded
        if (fullClose) {
            uint256 debtOver = params.market.debt.balanceOf(account);
            if (debtOver > 0) IMarginAccount(account).sweep(params.market.debt, debtOver, msgSender());
        }

        uint256 residual = params.market.collateral.balanceOfSelf() - balanceBefore;
        if (residual > 0) params.market.collateral.transfer(msgSender(), residual);

        // one event for both modes; `residual` is the realized PnL returned (zero on a partial
        // decrease). A full close ends empty by construction, so its resulting state is a known
        // zero and needs no position read; only a partial decrease reads back the shrunk position.
        if (fullClose) {
            emit PositionDecreased(
                msgSender(),
                account,
                params.market.collateral,
                params.market.debt,
                debt,
                collateralBefore,
                residual,
                0,
                0,
                Ltv.wrap(0),
                type(uint256).max
            );
        } else {
            PositionData memory position = params.adapter.describePosition(account, params.market);
            emit PositionDecreased(
                msgSender(),
                account,
                params.market.collateral,
                params.market.debt,
                params.debtToRepay,
                collateralBefore - position.collateralAmount,
                residual,
                position.collateralAmount,
                position.debtAmount,
                position.currentLtv,
                position.healthFactorWad
            );
        }
    }

    /// @inheritdoc IMarginRouter
    function addCollateral(AddCollateralParams calldata params)
        external
        payable
        isNotLocked
        checkDeadline(params.deadline)
        returns (address account)
    {
        _requireAllowedAdapter(params.adapter);
        account = createAccount(msgSender(), params.subId);

        uint256 amount;
        if (msg.value > 0) {
            // native collateral: wrap to WETH and credit the account
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
        PositionData memory position = params.adapter.describePosition(account, params.market);
        // no unlock means no action handler fires the snapshot; emit it here from the read above
        // (unguarded is fine: the supply is market-gated, so describePosition cannot be the revert).
        // PositionUpdated carries the full pair and maxLtv, which CollateralAdded does not, so
        // snapshot-only consumers can attribute the supply without pair-resolution heuristics.
        emit PositionUpdated(
            msgSender(),
            account,
            params.market.collateral,
            params.market.debt,
            position.collateralAmount,
            position.debtAmount,
            position.currentLtv,
            position.maxLtv,
            position.healthFactorWad
        );
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

    /// @inheritdoc IMarginRouter
    function execute(bytes calldata unlockData, uint256 deadline) external payable isNotLocked checkDeadline(deadline) {
        _executeActions(unlockData);
        // clear the active account so it cannot leak into a later multicall leg within the same
        // transaction (transient storage persists for the whole tx, not per external call). The
        // NoActiveAccount guard is the backstop, and any residual value is scoped to this locker's
        // own account regardless, so this is defense in depth.
        _setActiveAccount(address(0));
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

    /// @notice The governance address that curates the adapter allowlist.
    /// @return The current governance address.
    function governance() external view returns (address) {
        return _governance.read();
    }

    /// @notice The address proposed to become governance, pending its acceptance. Zero when no
    ///         handoff is in progress.
    /// @return The pending governance address.
    function pendingGovernance() external view returns (address) {
        return _governance.pendingOwner();
    }

    /// @notice Completes a governance handoff. Callable by anyone, but only the address previously
    ///         named by `transferGovernance` succeeds; all others revert. On success the caller
    ///         becomes governance.
    function acceptGovernance() external {
        address previousGovernance = _governance.read();
        _governance.acceptOwnership(msg.sender);
        emit GovernanceTransferred(previousGovernance, msg.sender);
    }

    /// @notice Whether `adapter` is on the governance allowlist and may be used in position flows.
    /// @param adapter The lending adapter to check.
    /// @return True if the adapter is allowlisted.
    function isAdapterAllowed(ILendingAdapter adapter) external view returns (bool) {
        return _allowedAdapters[adapter];
    }

    /// @notice The authenticated caller for the current lock. Overrides `BaseActionsRouter.msgSender`
    ///         to return the address stored by `ReentrancyLock._getLocker`, which is set to
    ///         `msg.sender` at the start of each `isNotLocked` call. The active account is derived
    ///         from this value, so correctness here is load-bearing for the entire position system.
    /// @return The authenticated caller (the locker set by `ReentrancyLock`) for the current unlock.
    function msgSender() public view override returns (address) {
        return _getLocker();
    }

    /// @notice Allows or disallows a lending adapter for use in the position flows. A non-allowlisted
    ///         adapter could redirect a caller's equity to an arbitrary destination, so the set is
    ///         curated by governance.
    /// @dev Only the current governance address may call this.
    /// @param adapter The lending adapter to allow or disallow.
    /// @param allowed True to allow; false to disallow.
    function setAdapterAllowed(ILendingAdapter adapter, bool allowed) external {
        _governance.onlyOwner(msg.sender);
        _allowedAdapters[adapter] = allowed;
        emit AdapterAllowed(address(adapter), allowed);
    }

    /// @notice Begins a two-step governance handoff by proposing a successor. The successor takes
    ///         effect only once it calls `acceptGovernance`; the current governance retains its
    ///         powers until then, and the zero address is rejected so the role cannot be bricked.
    /// @dev Only the current governance address may call this.
    /// @param newGovernance The address proposed to become the new governance.
    function transferGovernance(address newGovernance) external {
        _governance.onlyOwner(msg.sender);
        _governance.propose(newGovernance);
        emit GovernanceTransferStarted(msg.sender, newGovernance);
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
        // a zero buy would feed a zero amount into the exact-output swap, which the PoolManager rejects
        if (params.collateralToBuy == 0) revert ZeroAmount();
        if (params.maxDebtIn == 0) revert SlippageBoundRequired();
        // maxLtvAfter stays optional here (zero skips the check), but a supplied bound must be able to
        // bind: reject >= 100%, which would otherwise read as "set" yet disable ASSERT_HEALTH
        if (Ltv.unwrap(params.maxLtvAfter) != 0 && Ltv.unwrap(params.maxLtvAfter) >= WAD) {
            revert IneffectiveLtvBound(params.maxLtvAfter);
        }
        _requireAllowedAdapter(params.adapter);

        account = createAccount(msgSender(), params.subId);
        _setActiveAccount(account);

        // snapshot debt before drawing leverage so debtDrawn is correct whether this opens a fresh
        // position or increases an existing one
        (, debtBefore) = params.adapter.positionOf(account, params.market);

        // provide equity: native ETH (wrapped to WETH) when sent, else ERC20 pulled via Permit2
        if (msg.value > 0) {
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
        // route the debt->collateral swap through the Universal Router with the caller-supplied route,
        // behind a flash-take of up to maxDebtIn debt. The route buys collateralToBuy exact-output and
        // delivers it to the account, and ROUTE_SWAP settles the unspent take, so the router's remaining
        // debt equals exactly what the swap spent (the same negative delta a native v4 swap would leave).
        actionParams[0] = abi.encode(
            params.universalRouter,
            params.market.debt,
            uint256(params.maxDebtIn),
            params.routeCommands,
            params.routeInputs
        );
        // require the route to deliver the full collateralToBuy ON TOP of the balance the account
        // already holds going into the unlock (equity was transferred in above). Setting the
        // ASSERT_ACCOUNT_BALANCE threshold to `balance + collateralToBuy` makes the absolute check
        // enforce the SWAP DELTA, so a pre-existing, idle, cross-market, or donated balance cannot
        // mask an exact-output under-fill (audit M-03)
        uint256 collateralHeldBefore = params.market.collateral.balanceOf(account);
        actionParams[1] = abi.encode(params.market.collateral, collateralHeldBefore + params.collateralToBuy);
        // supply the account's full collateral balance (equity + bought)
        actionParams[2] = abi.encode(params.adapter, params.market, uint256(ActionConstants.OPEN_DELTA));
        // borrow the debt the swap cost (OPEN_DELTA == the router's remaining debt), to the router
        actionParams[3] = abi.encode(params.adapter, params.market, uint256(ActionConstants.OPEN_DELTA), address(this));
        // settle the swap's debt from the router (payer is this contract)
        actionParams[4] = abi.encode(params.market.debt, uint256(ActionConstants.OPEN_DELTA), false);
        // assert the resulting health against the caller's optional bound; a zero bound skips the
        // check, so callers relying only on `maxDebtIn` are unaffected
        actionParams[5] = abi.encode(params.adapter, params.market, params.maxLtvAfter);

        poolManager.unlock(abi.encode(actions, actionParams));
        _setActiveAccount(address(0));
    }

    /// @notice Reverts `AdapterNotAllowed` unless `adapter` is on the governance allowlist.
    /// @param adapter The adapter to check.
    function _requireAllowedAdapter(ILendingAdapter adapter) internal view {
        if (!_allowedAdapters[adapter]) revert AdapterNotAllowed(address(adapter));
    }

    /// @notice Dispatches one action from the current plan to its handler. Called by
    ///         `BaseActionsRouter._executeActions` for each action. Opcodes fall into three ranges,
    ///         checked in order:
    ///           1. below the margin range (`< ACCOUNT_SUPPLY_COLLATERAL`): inherited V4Router core
    ///              actions (swap/settle/take), plus the `SWEEP`/`WRAP`/`UNWRAP` trio this router
    ///              intercepts because V4Router does not handle it (`_handleCoreAction`).
    ///           2. account-independent margin actions (`SET_ACCOUNT`/`ASSERT_FILL`/`ROUTE_SWAP`):
    ///              they act on the router itself, so they run before the active-account guard.
    ///           3. account-scoped margin actions: everything else, which requires an active account
    ///              (`_handleAccountAction`).
    /// @dev Overrides `V4Router._handleAction`. The active account is always derived from the
    ///      authenticated caller and read from transient storage; it is never read from action params.
    /// @param action The opcode from `MarginActions` or the inherited `Actions` library.
    /// @param params ABI-encoded parameters for the action; decoded by `MarginCalldataDecoder`
    ///        (margin opcodes) or `CalldataDecoder` (the intercepted core opcodes).
    function _handleAction(uint256 action, bytes calldata params) internal override {
        // range 1: inherited core actions (swap/settle/take) and the intercepted SWEEP/WRAP/UNWRAP trio
        if (action < MarginActions.ACCOUNT_SUPPLY_COLLATERAL) {
            _handleCoreAction(action, params);
            return;
        }

        // range 2: margin actions that operate on the router, not an active account, so they run
        // before the NoActiveAccount guard below
        if (action == MarginActions.SET_ACCOUNT) {
            // account derived from the authenticated caller and this subId, never from calldata;
            // createAccount is idempotent, so re-selecting a live sub-account just re-binds it
            _setActiveAccount(createAccount(msgSender(), params.decodeSubId()));
            return;
        }
        if (action == MarginActions.ASSERT_FILL) {
            // require the router's own credit in the output currency covers `minAmount`, so a partial
            // exact-output fill reverts before it is taken
            (Currency currency, uint256 minAmount) = params.decodeFillCheck();
            uint256 received = _getFullCredit(currency);
            if (received < minAmount) revert IncompleteFill(minAmount, received);
            return;
        }
        if (action == MarginActions.ROUTE_SWAP) {
            _routeSwap(params);
            return;
        }

        // range 3: account-scoped. A plan must have bound the account with SET_ACCOUNT first; curated
        // entry points bind it before the unlock, so they never reach this revert.
        address account = _activeAccount();
        if (account == address(0)) revert NoActiveAccount();
        _handleAccountAction(action, params, account);
    }

    /// @notice Handles an opcode below the margin range. V4Router handles swaps and settle/take; this
    ///         router additionally intercepts the contiguous `SWEEP`/`WRAP`/`UNWRAP` trio (asserted
    ///         contiguous in MarginCalldataDecoder.t.sol), which V4Router would reject, with
    ///         PositionManager-identical semantics. A swap/settle/take opcode fails the first range
    ///         comparison and falls through to `super`.
    function _handleCoreAction(uint256 action, bytes calldata params) private {
        if (action >= Actions.SWEEP && action <= Actions.UNWRAP) {
            if (action == Actions.SWEEP) {
                (Currency currency, address to) = params.decodeCurrencyAndAddress();
                _sweep(currency, _mapRecipient(to));
            } else if (action == Actions.WRAP) {
                _wrap(
                    _mapWrapUnwrapAmount(
                        CurrencyLibrary.ADDRESS_ZERO, params.decodeUint256(), Currency.wrap(address(WETH9))
                    )
                );
            } else {
                _unwrap(
                    _mapWrapUnwrapAmount(
                        Currency.wrap(address(WETH9)), params.decodeUint256(), CurrencyLibrary.ADDRESS_ZERO
                    )
                );
            }
            return;
        }
        super._handleAction(action, params);
    }

    /// @notice Runs the `ROUTE_SWAP` action: route a swap through the Universal Router (v2/v3/v4)
    ///         behind a flash-take of the input. Because UR self-settles its own swap, wrapping the
    ///         call in a flash-take/settle envelope leaves the router owing exactly what UR spent — the
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

    /// @notice Dispatches an account-scoped margin opcode to its handler. Exposure-increasing
    ///         actions (supply, borrow) gate on the adapter allowlist inside their handlers;
    ///         exits (withdraw, repay, sweep) and assertions do not, so a position can always be
    ///         unwound even if the adapter has been deprecated.
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

    /// @notice Supplies collateral to the lending protocol on the account's behalf. Allowlist-gated
    ///         (supplying is exposure-increasing). `OPEN_DELTA` supplies the account's full collateral
    ///         balance (equity plus what the swap bought).
    function _supplyCollateral(bytes calldata params, address account) private {
        (ILendingAdapter adapter, Market memory market, uint256 amount) = params.decodeAdapterMarketAmount();
        _requireAllowedAdapter(adapter);
        if (amount == ActionConstants.OPEN_DELTA) amount = market.collateral.balanceOf(account);
        IMarginAccount(account).supplyCollateral(adapter, market, amount);
        _emitPosition(adapter, market, account);
    }

    /// @notice Borrows debt to `to`. Allowlist-gated (borrowing is exposure-increasing). `OPEN_DELTA`
    ///         borrows exactly the debt the swap owes the pool.
    function _borrow(bytes calldata params, address account) private {
        (ILendingAdapter adapter, Market memory market, uint256 amount, address to) =
            params.decodeAdapterMarketAmountReceiver();
        _requireAllowedAdapter(adapter);
        if (amount == ActionConstants.OPEN_DELTA) amount = _getFullDebt(market.debt);
        IMarginAccount(account).borrow(adapter, market, amount, to);
        _emitPosition(adapter, market, account);
    }

    /// @notice Withdraws collateral to `to`. Not allowlist-gated: a position must always be exitable.
    ///         `OPEN_DELTA` withdraws exactly the collateral the swap owes the pool (partial delever);
    ///         a full close passes the explicit full collateral amount.
    function _withdrawCollateral(bytes calldata params, address account) private {
        (ILendingAdapter adapter, Market memory market, uint256 amount, address to) =
            params.decodeAdapterMarketAmountReceiver();
        if (amount == ActionConstants.OPEN_DELTA) amount = _getFullDebt(market.collateral);
        IMarginAccount(account).withdrawCollateral(adapter, market, amount, to);
        _emitPosition(adapter, market, account);
    }

    /// @notice Repays debt to the lending protocol. Not allowlist-gated. `type(uint256).max` repays
    ///         all by shares (resolved by the adapter against the accrued balance).
    function _repay(bytes calldata params, address account) private {
        (ILendingAdapter adapter, Market memory market, uint256 amount) = params.decodeAdapterMarketAmount();
        IMarginAccount(account).repay(adapter, market, amount);
        _emitPosition(adapter, market, account);
    }

    /// @notice Emits a `PositionUpdated` snapshot for the account's `(collateral, debt)` market after a
    ///         mutation, so an `execute` plan is as observable as the curated entry points. Called after
    ///         every supply, withdraw, borrow, and repay dispatched through the unlock, and by the
    ///         zero-debt swap-free close (`addCollateral` emits the snapshot inline, reusing the
    ///         `describePosition` read it already makes).
    /// @dev Best-effort: `describePosition` reverts for a de-registered market, but withdraw and repay
    ///      are intentionally never market-gated (a position must always be exitable), so a failing read
    ///      is swallowed rather than reverting the action. `describePosition` is `view`, so the call is a
    ///      STATICCALL and a hostile adapter can neither reenter nor mutate state through it.
    function _emitPosition(ILendingAdapter adapter, Market memory market, address account) private {
        try adapter.describePosition(account, market) returns (PositionData memory position) {
            emit PositionUpdated(
                msgSender(),
                account,
                market.collateral,
                market.debt,
                position.collateralAmount,
                position.debtAmount,
                position.currentLtv,
                position.maxLtv,
                position.healthFactorWad
            );
        } catch {}
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
    ///         mask a short fill (audit M-03).
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
    ///         full-balance sentinel here — a pull with no amount is a plan-builder error, rejected
    ///         loudly. `CONTRACT_BALANCE` is honored only on the router-balance path.
    function _pullToAccount(bytes calldata params, address account) private {
        (Currency currency, uint256 amount, bool payerIsUser) = params.decodePull();
        if (amount == 0) revert ZeroAmount();
        if (payerIsUser) {
            // explicit amounts only: CONTRACT_BALANCE (1<<255) overflows the uint160 cast and reverts,
            // so the router-balance sentinel cannot be smuggled onto the caller
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

    /// @notice Stores the active account for the current unlock in transient storage (EIP-1153).
    ///         It is always derived from the authenticated caller stored by `ReentrancyLock`, never
    ///         from calldata, so margin handlers operate only on the caller's own account.
    /// @param account The MarginAccount address to store, or `address(0)` to clear after unlock.
    function _setActiveAccount(address account) private {
        bytes32 slot = ACTIVE_ACCOUNT_SLOT;
        assembly ("memory-safe") {
            tstore(slot, account)
        }
    }

    /// @notice Reads the active account from transient storage (EIP-1153). Returns `address(0)`
    ///         when no unlock is in progress.
    /// @return account The MarginAccount address active for the current unlock.
    function _activeAccount() private view returns (address account) {
        bytes32 slot = ACTIVE_ACCOUNT_SLOT;
        assembly ("memory-safe") {
            account := tload(slot)
        }
    }
}
