// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";

import {V4Router} from "./V4Router.sol";
import {ReentrancyLock} from "./base/ReentrancyLock.sol";
import {Permit2Forwarder} from "./base/Permit2Forwarder.sol";
import {Multicall_v4} from "./base/Multicall_v4.sol";
import {NativeWrapper} from "./base/NativeWrapper.sol";
import {IWETH9} from "./interfaces/external/IWETH9.sol";
import {IV4Router} from "./interfaces/IV4Router.sol";
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

    // transient slot holding the account for the current unlock, set from the authenticated caller
    bytes32 private constant ACTIVE_ACCOUNT_SLOT = keccak256("uniswap.marginRouter.activeAccount");

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
    ///      (`debtToRepay == type(uint256).max`) share one implementation: buy the target debt
    ///      exact-output, take it to the account, repay, withdraw collateral, and settle the swap from
    ///      the router. Only four things vary, all derived from `fullClose`: the swap size, the repay
    ///      amount, how much collateral is withdrawn, and the health bound. Everything else, including
    ///      the residual measure-and-forward, is identical: a partial decrease withdraws exactly the
    ///      swap cost so its residual is zero, while a full close withdraws everything and returns the
    ///      realized PnL.
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
        if (!fullClose && (params.debtToRepay == 0 || Ltv.unwrap(params.maxLtvAfter) == 0)) {
            revert SlippageBoundRequired();
        }

        account = accountOf(msgSender(), params.subId);
        (uint256 collateralBefore, uint256 debt) = params.adapter.positionOf(account, params.market);

        // a full close of a debt-free position (funded only via addCollateral, repaid out of band, or
        // fully liquidated) needs no swap: withdraw the collateral straight to the caller and finish.
        if (fullClose && debt == 0) {
            if (collateralBefore > 0) {
                IMarginAccount(account).withdrawCollateral(params.adapter, params.market, collateralBefore, msgSender());
            }
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
            uint8(Actions.SWAP_EXACT_OUT_SINGLE),
            uint8(MarginActions.ASSERT_FILL),
            uint8(Actions.TAKE),
            uint8(MarginActions.ACCOUNT_REPAY),
            uint8(MarginActions.ACCOUNT_WITHDRAW_COLLATERAL),
            uint8(Actions.SETTLE),
            uint8(MarginActions.ASSERT_HEALTH)
        );
        // the mode-dependent amounts are inlined (kept out of locals to stay under the stack limit):
        // full close buys the whole debt and repays ALL by shares so no borrow-share dust remains (an
        // asset-denominated repay leaves rounding dust that would fail the full-collateral withdrawal's
        // health check), withdraws all collateral, and passes a zero health bound that ASSERT_HEALTH
        // skips. A partial decrease buys and repays exactly `debtToRepay`, withdraws only the collateral
        // the swap consumed (OPEN_DELTA), and enforces `maxLtvAfter`.
        bytes[] memory actionParams = new bytes[](7);
        actionParams[0] = abi.encode(
            IV4Router.ExactOutputSingleParams({
                poolKey: params.poolKey,
                zeroForOne: params.market.toSwapParams(params.market.collateral, 0, 0, params.poolKey).zeroForOne,
                amountOut: (fullClose ? debt : params.debtToRepay).toUint128(),
                amountInMaximum: params.maxCollateralIn,
                minHopPriceX36: params.minHopPriceX36,
                hookData: ""
            })
        );
        // assert the exact-output swap fully filled before taking: a thin pool can hit its price limit
        // before buying the full debt, and an under-fill would otherwise surface as an opaque repay
        // revert. Require the router's debt credit covers the amount the repay needs.
        actionParams[1] = abi.encode(params.market.debt, fullClose ? debt : params.debtToRepay);
        actionParams[2] = abi.encode(params.market.debt, account, ActionConstants.OPEN_DELTA);
        actionParams[3] = abi.encode(params.adapter, params.market, fullClose ? type(uint256).max : params.debtToRepay);
        actionParams[4] = abi.encode(
            params.adapter,
            params.market,
            fullClose ? collateralBefore : uint256(ActionConstants.OPEN_DELTA),
            address(this)
        );
        actionParams[5] = abi.encode(params.market.collateral, uint256(ActionConstants.OPEN_DELTA), false);
        actionParams[6] = abi.encode(params.adapter, params.market, fullClose ? Ltv.wrap(0) : params.maxLtvAfter);

        // measure the router's own collateral gain across the unlock: zero for a partial decrease (it
        // withdraws exactly the swap cost), the realized PnL for a full close
        uint256 balanceBefore = params.market.collateral.balanceOfSelf();
        poolManager.unlock(abi.encode(actions, actionParams));
        _setActiveAccount(address(0));

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
            if (params.amount == 0) revert SlippageBoundRequired();
            amount = params.amount;
            permit2.transferFrom(
                msgSender(), account, params.amount.toUint160(), Currency.unwrap(params.market.collateral)
            );
        }
        // the router is the account manager, so it can supply directly without an unlock
        IMarginAccount(account).supplyCollateral(params.adapter, params.market, amount);
        PositionData memory position = params.adapter.describePosition(account, params.market);
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
        if (params.collateralToBuy == 0) revert SlippageBoundRequired();
        if (params.maxDebtIn == 0) revert SlippageBoundRequired();
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

        // single choke point: validate the pool matches the market and derive the swap direction.
        // opening sells the debt to buy the collateral.
        bool zeroForOne = params.market.toSwapParams(params.market.debt, 0, 0, params.poolKey).zeroForOne;

        bytes memory actions = abi.encodePacked(
            uint8(Actions.SWAP_EXACT_OUT_SINGLE),
            uint8(MarginActions.ASSERT_FILL),
            uint8(Actions.TAKE),
            uint8(MarginActions.ACCOUNT_SUPPLY_COLLATERAL),
            uint8(MarginActions.ACCOUNT_BORROW),
            uint8(Actions.SETTLE)
        );
        bytes[] memory actionParams = new bytes[](6);
        actionParams[0] = abi.encode(
            IV4Router.ExactOutputSingleParams({
                poolKey: params.poolKey,
                zeroForOne: zeroForOne,
                amountOut: params.collateralToBuy,
                amountInMaximum: params.maxDebtIn,
                minHopPriceX36: params.minHopPriceX36,
                hookData: ""
            })
        );
        // assert the exact-output swap fully filled: a v4 swap can partial-fill on a thin pool (the
        // price hits the global limit before the full output is bought). Without this the open would
        // take only the realized amount and silently open a smaller position. Asserting the router
        // holds the full collateralToBuy credit makes the open all-or-nothing with a clear error.
        actionParams[1] = abi.encode(params.market.collateral, uint256(params.collateralToBuy));
        // take the bought collateral to the account (OPEN_DELTA == the full fill the assert just proved)
        actionParams[2] = abi.encode(params.market.collateral, account, ActionConstants.OPEN_DELTA);
        // supply the account's full collateral balance (equity + bought)
        actionParams[3] = abi.encode(params.adapter, params.market, uint256(ActionConstants.OPEN_DELTA));
        // borrow the debt owed for the swap, sent to the router for settling
        actionParams[4] = abi.encode(params.adapter, params.market, uint256(ActionConstants.OPEN_DELTA), address(this));
        // settle the swap's debt from the router (payer is this contract)
        actionParams[5] = abi.encode(params.market.debt, uint256(ActionConstants.OPEN_DELTA), false);

        poolManager.unlock(abi.encode(actions, actionParams));
        _setActiveAccount(address(0));
    }

    /// @notice Reverts `AdapterNotAllowed` unless `adapter` is on the governance allowlist.
    /// @param adapter The adapter to check.
    function _requireAllowedAdapter(ILendingAdapter adapter) internal view {
        if (!_allowedAdapters[adapter]) revert AdapterNotAllowed(address(adapter));
    }

    /// @notice Dispatches an action to the correct handler across three ranges: (1) opcodes below
    ///         `0x30` go to the inherited V4Router handlers (swap, settle, take), except the
    ///         contiguous `SWEEP`/`WRAP`/`UNWRAP` trio, which V4Router does not handle and this
    ///         contract intercepts with PositionManager-identical semantics; (2) `SET_ACCOUNT` and
    ///         `ASSERT_FILL`, which do not operate on an active account; (3) the remaining
    ///         account-scoped margin opcodes, guarded by `NoActiveAccount`. Called by
    ///         `BaseActionsRouter._executeActions` for each action in the current plan.
    /// @dev Overrides `V4Router._handleAction`. The active account is always derived from the
    ///      authenticated caller (via `SET_ACCOUNT` or a curated entry point) and read from
    ///      transient storage; it is never read from action params.
    /// @param action The opcode from `MarginActions` or the inherited `Actions` library.
    /// @param params ABI-encoded parameters for the action; decoded by `MarginCalldataDecoder`
    ///        (margin opcodes) or `CalldataDecoder` (the intercepted core opcodes).
    function _handleAction(uint256 action, bytes calldata params) internal override {
        if (action < MarginActions.ACCOUNT_SUPPLY_COLLATERAL) {
            // SWEEP/WRAP/UNWRAP are a contiguous trio (asserted in MarginCalldataDecoder.t.sol)
            // that V4Router does not handle (it would revert UnsupportedAction); intercept them
            // here with PositionManager-identical semantics. Swap and settle/take opcodes (below
            // SWEEP) pay only one failed range comparison before falling through to super.
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
            return;
        }

        // SET_ACCOUNT binds the active account; ASSERT_FILL only reads the router's own swap
        // credit. Neither operates on an already-active account, so both dispatch before the
        // NoActiveAccount guard below.
        if (action == MarginActions.SET_ACCOUNT) {
            // account derived from the authenticated caller, never from calldata; createAccount is
            // idempotent, so a repeat SET_ACCOUNT on an existing sub-account just re-activates it
            _setActiveAccount(createAccount(msgSender(), params.decodeSubId()));
            return;
        }
        if (action == MarginActions.ASSERT_FILL) {
            // the router's credit in the swap output currency is the realized exact-output fill;
            // require it covers the requested amount so a partial fill reverts before the take
            (Currency currency, uint256 minAmount) = params.decodeFillCheck();
            uint256 received = _getFullCredit(currency);
            if (received < minAmount) revert IncompleteFill(minAmount, received);
            return;
        }

        // every remaining opcode operates on the active account; a plan must set it with
        // SET_ACCOUNT first. Curated entry points set it before unlock and never reach this revert.
        address account = _activeAccount();
        if (account == address(0)) revert NoActiveAccount();

        if (action == MarginActions.ACCOUNT_SUPPLY_COLLATERAL) {
            (ILendingAdapter adapter, Market memory market, uint256 amount) = params.decodeAdapterMarketAmount();
            // supplying collateral is exposure-increasing, so it is gated on the adapter allowlist
            _requireAllowedAdapter(adapter);
            if (amount == ActionConstants.OPEN_DELTA) amount = market.collateral.balanceOf(account);
            IMarginAccount(account).supplyCollateral(adapter, market, amount);
        } else if (action == MarginActions.ACCOUNT_WITHDRAW_COLLATERAL) {
            (ILendingAdapter adapter, Market memory market, uint256 amount, address to) =
                params.decodeAdapterMarketAmountReceiver();
            // OPEN_DELTA withdraws exactly the collateral owed to the pool for the swap (partial
            // delever); a full close passes the explicit full collateral amount instead. Not
            // allowlist-gated: a position must always be exitable.
            if (amount == ActionConstants.OPEN_DELTA) amount = _getFullDebt(market.collateral);
            IMarginAccount(account).withdrawCollateral(adapter, market, amount, to);
        } else if (action == MarginActions.ACCOUNT_BORROW) {
            (ILendingAdapter adapter, Market memory market, uint256 amount, address to) =
                params.decodeAdapterMarketAmountReceiver();
            // borrowing is exposure-increasing, so it is gated on the adapter allowlist
            _requireAllowedAdapter(adapter);
            if (amount == ActionConstants.OPEN_DELTA) amount = _getFullDebt(market.debt);
            IMarginAccount(account).borrow(adapter, market, amount, to);
        } else if (action == MarginActions.ACCOUNT_REPAY) {
            (ILendingAdapter adapter, Market memory market, uint256 amount) = params.decodeAdapterMarketAmount();
            IMarginAccount(account).repay(adapter, market, amount);
        } else if (action == MarginActions.ACCOUNT_SWEEP) {
            (Currency currency, uint256 amount, address to) = params.decodeSweep();
            IMarginAccount(account).sweep(currency, amount, to);
        } else if (action == MarginActions.ASSERT_HEALTH) {
            (ILendingAdapter adapter, Market memory market, Ltv maxLtv) = params.decodeHealthCheck();
            // a zero bound skips the check
            if (Ltv.unwrap(maxLtv) != 0 && adapter.currentLtvWad(account, market).gt(maxLtv)) {
                revert PositionUnhealthy();
            }
        } else if (action == MarginActions.PULL_TO_ACCOUNT) {
            (Currency currency, uint256 amount, bool payerIsUser) = params.decodePull();
            // unlike the pool-delta opcodes, 0 is not an OPEN_DELTA full-balance sentinel here; a
            // pull with no amount is always a plan-builder error, so reject it loudly rather than
            // silently moving nothing (which would compose badly with opt-in health checks)
            if (amount == 0) revert SlippageBoundRequired();
            if (payerIsUser) {
                // explicit amounts only: CONTRACT_BALANCE (1<<255) overflows the uint160 cast and
                // reverts, so the router-balance sentinel cannot be smuggled onto the caller
                permit2.transferFrom(msgSender(), account, amount.toUint160(), Currency.unwrap(currency));
            } else {
                if (amount == ActionConstants.CONTRACT_BALANCE) amount = currency.balanceOfSelf();
                currency.transfer(account, amount);
            }
        } else {
            revert UnsupportedAction(action);
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
            permit2.transferFrom(payer, address(poolManager), uint160(amount), Currency.unwrap(currency));
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
