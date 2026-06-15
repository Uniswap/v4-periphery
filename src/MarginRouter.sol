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

/// @notice The brain of the margin-trading suite. Composes the v4 action machinery and builds each
///         leveraged position as a single flash-style swap inside one PoolManager unlock: borrow the
///         debt, swap it into collateral, supply the collateral, then draw the debt to settle. Each
///         operation runs against the caller's own MarginAccount, derived from the authenticated
///         caller (never from a caller-supplied address). The router is the manager of every account
///         it deploys, so it can drive their lending primitives.
///
///         Supported markets are restricted to the governance allowlist of lending adapters, which
///         curate standard ERC20 markets only (Morpho Blue does not support fee-on-transfer or
///         rebasing tokens). Under that constraint every flow nets to zero with no router residual.
contract MarginRouter is IMarginRouter, V4Router, ReentrancyLock, Permit2Forwarder, Multicall_v4, NativeWrapper {
    using MarginCalldataDecoder for bytes;
    using SafeCast for uint256;

    // transient slot holding the account for the current unlock, set from the authenticated caller
    bytes32 private constant ACTIVE_ACCOUNT_SLOT = keccak256("uniswap.marginRouter.activeAccount");

    /// @notice The factory that deploys and addresses per-user accounts. Manager of every account.
    MarginAccountFactory public immutable factory;

    Owner internal _governance;
    mapping(ILendingAdapter adapter => bool isAllowed) internal _allowedAdapters;

    /// @notice Emitted when governance allows or disallows a lending adapter.
    event AdapterAllowed(address indexed adapter, bool allowed);

    constructor(IPoolManager poolManager_, IAllowanceTransfer permit2_, IWETH9 weth9_, address accountImplementation)
        V4Router(poolManager_)
        Permit2Forwarder(permit2_)
        NativeWrapper(weth9_)
    {
        factory = new MarginAccountFactory(accountImplementation, address(this));
        // the deployer is the initial governance; hand off to a timelock or multisig after setup
        _governance.write(msg.sender);
    }

    /// @notice The governance address that curates the adapter allowlist.
    function governance() external view returns (address) {
        return _governance.read();
    }

    /// @notice Hands governance to a new address. Governance-gated.
    function transferGovernance(address newGovernance) external {
        _governance.onlyOwner(msg.sender);
        _governance.write(newGovernance);
    }

    /// @notice Allows or disallows a lending adapter for use in the flows. Governance-gated.
    /// @dev Only allowlisted adapters can be passed to the position flows. A hostile adapter can
    ///      otherwise siphon the caller's own equity, so the set is curated.
    function setAdapterAllowed(ILendingAdapter adapter, bool allowed) external {
        _governance.onlyOwner(msg.sender);
        _allowedAdapters[adapter] = allowed;
        emit AdapterAllowed(address(adapter), allowed);
    }

    /// @notice Whether `adapter` is allowlisted.
    function isAdapterAllowed(ILendingAdapter adapter) external view returns (bool) {
        return _allowedAdapters[adapter];
    }

    modifier checkDeadline(uint256 deadline) {
        if (block.timestamp > deadline) revert DeadlinePassed(deadline);
        _;
    }

    /// @inheritdoc IMarginRouter
    function openPosition(OpenParams calldata params)
        external
        isNotLocked
        checkDeadline(params.deadline)
        returns (address account)
    {
        account = _open(params);
        emit PositionOpened(
            msgSender(), account, params.market.collateral, params.market.debt, params.collateralToBuy
        );
    }

    /// @inheritdoc IMarginRouter
    function increasePosition(OpenParams calldata params)
        external
        isNotLocked
        checkDeadline(params.deadline)
        returns (address account)
    {
        account = _open(params);
        emit PositionIncreased(
            msgSender(), account, params.market.collateral, params.market.debt, params.collateralToBuy
        );
    }

    /// @notice Shared lever-up: deploy the account if needed, pull optional equity, then build and
    ///         run the flash-style plan (swap debt to collateral, supply, borrow, settle).
    function _open(OpenParams calldata params) private returns (address account) {
        if (params.maxDebtIn == 0) revert SlippageBoundRequired();
        _requireAllowedAdapter(params.adapter);

        account = factory.createAccount(msgSender(), params.subId);
        _setActiveAccount(account);

        // pull the caller's equity (in the collateral currency) into the account
        if (params.equity > 0) {
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
        actionParams[3] =
            abi.encode(params.adapter, params.market, uint256(ActionConstants.OPEN_DELTA), address(this));
        // settle the swap's debt from the router (payer is this contract)
        actionParams[4] = abi.encode(params.market.debt, uint256(ActionConstants.OPEN_DELTA), false);

        poolManager.unlock(abi.encode(actions, actionParams));
        _setActiveAccount(address(0));
    }

    /// @inheritdoc IMarginRouter
    function closePosition(CloseParams calldata params)
        external
        isNotLocked
        checkDeadline(params.deadline)
        returns (address account)
    {
        if (params.maxCollateralIn == 0) revert SlippageBoundRequired();
        _requireAllowedAdapter(params.adapter);

        account = factory.accountOf(msgSender(), params.subId);
        _setActiveAccount(account);

        // buy exactly the current debt, then repay it; sell collateral to fund the purchase
        (uint256 collateral, uint256 debt) = params.adapter.positionOf(account, params.market);
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
        // must not be left free to worsen the position's LTV
        if (params.maxCollateralIn == 0 || Ltv.unwrap(params.maxLtvAfter) == 0) revert SlippageBoundRequired();
        _requireAllowedAdapter(params.adapter);

        account = factory.accountOf(msgSender(), params.subId);
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
        actionParams[3] =
            abi.encode(params.adapter, params.market, uint256(ActionConstants.OPEN_DELTA), address(this));
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
        isNotLocked
        checkDeadline(params.deadline)
        returns (address account)
    {
        if (params.amount == 0) revert SlippageBoundRequired();
        _requireAllowedAdapter(params.adapter);

        account = factory.createAccount(msgSender(), params.subId);
        permit2.transferFrom(
            msgSender(), account, params.amount.toUint160(), Currency.unwrap(params.market.collateral)
        );
        // the router is the account manager, so it can supply directly without an unlock
        IMarginAccount(account).supplyCollateral(params.adapter, params.market, params.amount);
        emit CollateralAdded(msgSender(), account, params.market.collateral, params.amount);
    }

    /// @inheritdoc IMarginRouter
    function accountOf(address owner, uint256 subId) external view returns (address) {
        return factory.accountOf(owner, subId);
    }

    /// @notice Dispatches margin opcodes to the active account; everything else falls through to the
    ///         inherited V4Router handlers (swap, take, settle).
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

    /// @notice The authenticated caller for the current lock. Load-bearing: the active account is
    ///         derived from this, so it must return the locker.
    function msgSender() public view override returns (address) {
        return _getLocker();
    }

    /// @notice Pays the pool manager. The router (address(this)) transfers directly; any other payer
    ///         pays through Permit2. Mirrors the PositionManager two-payer settle.
    function _pay(Currency currency, address payer, uint256 amount) internal override {
        if (payer == address(this)) {
            currency.transfer(address(poolManager), amount);
        } else {
            permit2.transferFrom(payer, address(poolManager), uint160(amount), Currency.unwrap(currency));
        }
    }

    /// @notice Reverts unless `adapter` is on the governance allowlist.
    function _requireAllowedAdapter(ILendingAdapter adapter) internal view {
        if (!_allowedAdapters[adapter]) revert AdapterNotAllowed(address(adapter));
    }

    /// @notice Stores the active account for the current unlock in transient storage (EIP-1153). It
    ///         is always derived from the authenticated caller, never from calldata, so the margin
    ///         handlers operate only on the caller's own account.
    function _setActiveAccount(address account) private {
        bytes32 slot = ACTIVE_ACCOUNT_SLOT;
        assembly ("memory-safe") {
            tstore(slot, account)
        }
    }

    function _activeAccount() private view returns (address account) {
        bytes32 slot = ACTIVE_ACCOUNT_SLOT;
        assembly ("memory-safe") {
            account := tload(slot)
        }
    }
}
