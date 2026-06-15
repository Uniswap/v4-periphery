// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

import {V4Router} from "./V4Router.sol";
import {ReentrancyLock} from "./base/ReentrancyLock.sol";
import {Permit2Forwarder} from "./base/Permit2Forwarder.sol";
import {Multicall_v4} from "./base/Multicall_v4.sol";
import {NativeWrapper} from "./base/NativeWrapper.sol";
import {IWETH9} from "./interfaces/external/IWETH9.sol";
import {IV4Router} from "./interfaces/IV4Router.sol";
import {Actions} from "./libraries/Actions.sol";
import {ActionConstants} from "./libraries/ActionConstants.sol";

import {IMarginRouter} from "./interfaces/IMarginRouter.sol";
import {IMarginAccount} from "./interfaces/IMarginAccount.sol";
import {ILendingAdapter} from "./interfaces/ILendingAdapter.sol";
import {MarginAccountFactory} from "./MarginAccountFactory.sol";
import {MarginActions} from "./libraries/MarginActions.sol";
import {MarginCalldataDecoder} from "./libraries/MarginCalldataDecoder.sol";
import {Market} from "./types/Market.sol";
import {Ltv} from "./types/Ltv.sol";
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
///         curate standard ERC-20 markets only (Morpho Blue does not support fee-on-transfer or
///         rebasing tokens). Under that constraint every flow nets to zero with no router residual.
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
    using SafeCast for uint256;

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

    constructor(IPoolManager poolManager_, IAllowanceTransfer permit2_, IWETH9 weth9_, address accountImplementation)
        V4Router(poolManager_)
        Permit2Forwarder(permit2_)
        NativeWrapper(weth9_)
        MarginAccountFactory(accountImplementation)
    {
        // the deployer is the initial governance; hand off to a timelock or multisig after setup
        _governance.write(msg.sender);
    }

    /// @inheritdoc IMarginRouter
    function openPosition(OpenParams calldata params)
        external
        payable
        isNotLocked
        checkDeadline(params.deadline)
        returns (address account)
    {
        account = _open(params);
        emit PositionOpened(msgSender(), account, params.market.collateral, params.market.debt, params.collateralToBuy);
    }

    /// @inheritdoc IMarginRouter
    function increasePosition(OpenParams calldata params)
        external
        payable
        isNotLocked
        checkDeadline(params.deadline)
        returns (address account)
    {
        account = _open(params);
        emit PositionIncreased(
            msgSender(), account, params.market.collateral, params.market.debt, params.collateralToBuy
        );
    }

    /// @inheritdoc IMarginRouter
    function closePosition(CloseParams calldata params)
        external
        isNotLocked
        checkDeadline(params.deadline)
        returns (address account)
    {
        account = accountOf(msgSender(), params.subId);

        // resolve the position before deciding whether a swap is required
        (uint256 collateral, uint256 debt) = params.adapter.positionOf(account, params.market);

        // a position with no debt (e.g. funded only via addCollateral, repaid out of band, or fully
        // liquidated) needs no swap: withdraw the collateral straight to the caller and finish. The
        // router is the account manager and msgSender() is the owner, both allowed receivers.
        if (debt == 0) {
            if (collateral > 0) {
                IMarginAccount(account).withdrawCollateral(params.adapter, params.market, collateral, msgSender());
            }
            emit PositionClosed(msgSender(), account, params.market.collateral, params.market.debt, collateral);
            return account;
        }

        if (params.maxCollateralIn == 0) revert SlippageBoundRequired();
        _requireAllowedAdapter(params.adapter);
        _setActiveAccount(account);

        // buy exactly the current debt, then repay it; sell collateral to fund the purchase
        bool zeroForOne = params.market.toSwapParams(params.market.collateral, 0, 0, params.poolKey).zeroForOne;

        bytes memory actions = abi.encodePacked(
            uint8(Actions.SWAP_EXACT_OUT_SINGLE),
            uint8(Actions.TAKE),
            uint8(MarginActions.ACCOUNT_REPAY),
            uint8(MarginActions.ACCOUNT_WITHDRAW_COLLATERAL),
            uint8(Actions.SETTLE)
        );
        bytes[] memory actionParams = new bytes[](5);
        actionParams[0] = abi.encode(
            IV4Router.ExactOutputSingleParams({
                poolKey: params.poolKey,
                zeroForOne: zeroForOne,
                amountOut: debt.toUint128(),
                amountInMaximum: params.maxCollateralIn,
                minHopPriceX36: params.minHopPriceX36,
                hookData: ""
            })
        );
        // take the bought debt to the account, then repay ALL by shares so no borrow-share dust
        // remains (an asset-denominated repay rounds down to shares and leaves dust, which would
        // make the full-collateral withdrawal fail the lending market's health check). The bought
        // `debt` equals expectedBorrowAssets, which is exactly what a full-share repay pulls in the
        // same block.
        actionParams[1] = abi.encode(params.market.debt, account, ActionConstants.OPEN_DELTA);
        actionParams[2] = abi.encode(params.adapter, params.market, type(uint256).max);
        actionParams[3] = abi.encode(params.adapter, params.market, collateral, address(this));
        // settle the collateral spent on the swap from the router
        actionParams[4] = abi.encode(params.market.collateral, uint256(ActionConstants.OPEN_DELTA), false);

        poolManager.unlock(abi.encode(actions, actionParams));
        _setActiveAccount(address(0));

        // return the remaining collateral (realized PnL) to the caller
        uint256 residual = params.market.collateral.balanceOfSelf();
        if (residual > 0) params.market.collateral.transfer(msgSender(), residual);
        emit PositionClosed(msgSender(), account, params.market.collateral, params.market.debt, residual);
    }

    /// @inheritdoc IMarginRouter
    function decreasePosition(DecreaseParams calldata params)
        external
        isNotLocked
        checkDeadline(params.deadline)
        returns (address account)
    {
        // both the collateral slippage bound and the resulting-health bound are mandatory: a delever
        // must not be left free to worsen the position's LTV. A zero repay would feed a zero amount
        // into the exact-output swap, which the PoolManager rejects.
        if (params.debtToRepay == 0) revert SlippageBoundRequired();
        if (params.maxCollateralIn == 0 || Ltv.unwrap(params.maxLtvAfter) == 0) revert SlippageBoundRequired();
        _requireAllowedAdapter(params.adapter);

        account = accountOf(msgSender(), params.subId);
        _setActiveAccount(account);

        // sell collateral to buy and repay `debtToRepay`; the position stays open and shrinks
        bool zeroForOne = params.market.toSwapParams(params.market.collateral, 0, 0, params.poolKey).zeroForOne;

        bytes memory actions = abi.encodePacked(
            uint8(Actions.SWAP_EXACT_OUT_SINGLE),
            uint8(Actions.TAKE),
            uint8(MarginActions.ACCOUNT_REPAY),
            uint8(MarginActions.ACCOUNT_WITHDRAW_COLLATERAL),
            uint8(Actions.SETTLE),
            uint8(MarginActions.ASSERT_HEALTH)
        );
        bytes[] memory actionParams = new bytes[](6);
        actionParams[0] = abi.encode(
            IV4Router.ExactOutputSingleParams({
                poolKey: params.poolKey,
                zeroForOne: zeroForOne,
                amountOut: params.debtToRepay.toUint128(),
                amountInMaximum: params.maxCollateralIn,
                minHopPriceX36: params.minHopPriceX36,
                hookData: ""
            })
        );
        actionParams[1] = abi.encode(params.market.debt, account, ActionConstants.OPEN_DELTA);
        actionParams[2] = abi.encode(params.adapter, params.market, params.debtToRepay);
        // withdraw only the collateral the swap consumed (OPEN_DELTA = collateral owed to the pool)
        actionParams[3] = abi.encode(params.adapter, params.market, uint256(ActionConstants.OPEN_DELTA), address(this));
        actionParams[4] = abi.encode(params.market.collateral, uint256(ActionConstants.OPEN_DELTA), false);
        // assert the resulting health
        actionParams[5] = abi.encode(params.adapter, params.market, account, params.maxLtvAfter);

        poolManager.unlock(abi.encode(actions, actionParams));
        _setActiveAccount(address(0));
        emit PositionDecreased(msgSender(), account, params.market.collateral, params.market.debt, params.debtToRepay);
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
        emit CollateralAdded(msgSender(), account, params.market.collateral, amount);
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

    /// @notice Shared implementation for `openPosition` and `increasePosition`. Deploys the account
    ///         if needed, pulls optional equity, then builds and runs the flash-style unlock:
    ///         swap debt to collateral (exact-output), supply the collateral, borrow the debt owed,
    ///         and settle the swap.
    /// @param params The open/increase parameters; see `OpenParams`.
    /// @return account The caller's MarginAccount address.
    function _open(OpenParams calldata params) private returns (address account) {
        // a zero buy would feed a zero amount into the exact-output swap, which the PoolManager rejects
        if (params.collateralToBuy == 0) revert SlippageBoundRequired();
        if (params.maxDebtIn == 0) revert SlippageBoundRequired();
        _requireAllowedAdapter(params.adapter);

        account = createAccount(msgSender(), params.subId);
        _setActiveAccount(account);

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
            uint8(Actions.TAKE),
            uint8(MarginActions.ACCOUNT_SUPPLY_COLLATERAL),
            uint8(MarginActions.ACCOUNT_BORROW),
            uint8(Actions.SETTLE)
        );
        bytes[] memory actionParams = new bytes[](5);
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
        // take the bought collateral to the account
        actionParams[1] = abi.encode(params.market.collateral, account, ActionConstants.OPEN_DELTA);
        // supply the account's full collateral balance (equity + bought)
        actionParams[2] = abi.encode(params.adapter, params.market, uint256(ActionConstants.OPEN_DELTA));
        // borrow the debt owed for the swap, sent to the router for settling
        actionParams[3] = abi.encode(params.adapter, params.market, uint256(ActionConstants.OPEN_DELTA), address(this));
        // settle the swap's debt from the router (payer is this contract)
        actionParams[4] = abi.encode(params.market.debt, uint256(ActionConstants.OPEN_DELTA), false);

        poolManager.unlock(abi.encode(actions, actionParams));
        _setActiveAccount(address(0));
    }

    /// @notice Reverts `AdapterNotAllowed` unless `adapter` is on the governance allowlist.
    /// @param adapter The adapter to check.
    function _requireAllowedAdapter(ILendingAdapter adapter) internal view {
        if (!_allowedAdapters[adapter]) revert AdapterNotAllowed(address(adapter));
    }

    /// @notice Dispatches margin opcodes (`>= 0x30`) to the active account; opcodes below `0x30`
    ///         fall through to the inherited V4Router handlers (swap, take, settle, wrap, unwrap).
    ///         Called by `BaseActionsRouter._executeActions` for each action in the current plan.
    /// @dev Overrides `V4Router._handleAction`. The active account is always derived from the
    ///      authenticated caller stored in transient storage; it is never read from action params.
    /// @param action The opcode from `MarginActions` or the inherited `Actions` library.
    /// @param params ABI-encoded parameters for the action; decoded by `MarginCalldataDecoder`.
    function _handleAction(uint256 action, bytes calldata params) internal override {
        if (action < MarginActions.ACCOUNT_SUPPLY_COLLATERAL) {
            super._handleAction(action, params);
            return;
        }

        address account = _activeAccount();
        if (action == MarginActions.ACCOUNT_SUPPLY_COLLATERAL) {
            (ILendingAdapter adapter, Market memory market, uint256 amount) = params.decodeAdapterMarketAmount();
            if (amount == 0) amount = IERC20(Currency.unwrap(market.collateral)).balanceOf(account);
            IMarginAccount(account).supplyCollateral(adapter, market, amount);
        } else if (action == MarginActions.ACCOUNT_WITHDRAW_COLLATERAL) {
            (ILendingAdapter adapter, Market memory market, uint256 amount, address to) =
                params.decodeAdapterMarketAmountReceiver();
            // OPEN_DELTA withdraws exactly the collateral owed to the pool for the swap (partial
            // delever); a full close passes the explicit full collateral amount instead
            if (amount == 0) amount = _getFullDebt(market.collateral);
            IMarginAccount(account).withdrawCollateral(adapter, market, amount, to);
        } else if (action == MarginActions.ACCOUNT_BORROW) {
            (ILendingAdapter adapter, Market memory market, uint256 amount, address to) =
                params.decodeAdapterMarketAmountReceiver();
            if (amount == 0) amount = _getFullDebt(market.debt);
            IMarginAccount(account).borrow(adapter, market, amount, to);
        } else if (action == MarginActions.ACCOUNT_REPAY) {
            (ILendingAdapter adapter, Market memory market, uint256 amount) = params.decodeAdapterMarketAmount();
            IMarginAccount(account).repay(adapter, market, amount);
        } else if (action == MarginActions.ACCOUNT_SWEEP) {
            (Currency currency, uint256 amount, address to) = params.decodeSweep();
            IMarginAccount(account).sweep(currency, amount, to);
        } else if (action == MarginActions.ASSERT_HEALTH) {
            (ILendingAdapter adapter, Market memory market,, Ltv maxLtv) = params.decodeHealthCheck();
            // a zero bound skips the check
            if (Ltv.unwrap(maxLtv) != 0 && adapter.currentLtvWad(account, market).gt(maxLtv)) {
                revert PositionUnhealthy();
            }
        } else {
            revert UnsupportedAction(action);
        }
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
