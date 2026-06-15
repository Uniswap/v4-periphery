// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {ILendingAdapter} from "./interfaces/ILendingAdapter.sol";
import {IPool} from "./interfaces/external/aave/IPool.sol";
import {IPoolAddressesProvider} from "./interfaces/external/aave/IPoolAddressesProvider.sol";
import {IPoolDataProvider} from "./interfaces/external/aave/IPoolDataProvider.sol";
import {Market} from "./types/Market.sol";
import {Owner} from "./types/Owner.sol";
import {Ltv, toLtv} from "./types/Ltv.sol";

/// @title AaveLendingAdapter
/// @author Uniswap Labs
/// @notice A singleton `ILendingAdapter` over the Aave v3 Pool. The adapter is a thin shell composing
///         a governed `(collateral, debt)` allowlist and an owner guard; all encode and read logic
///         delegates to the Aave Pool and the protocol data provider, so no Aave math is
///         reimplemented. Each encoded call is executed by a `MarginAccount` as itself, so the Aave
///         `onBehalfOf` is always the account and no delegated authorization is needed. The
///         motivating use case is a short ETH position: supply USDC as collateral and borrow WETH.
/// @custom:security-contact security@uniswap.org
contract AaveLendingAdapter is ILendingAdapter {
    // WAD scale for loan-to-value ratios.
    uint256 private constant WAD = 1e18;
    // Aave expresses LTV and liquidation thresholds in basis points (1e4 == 100%).
    uint256 private constant BPS = 1e4;
    // Aave interest rate mode for variable-rate debt (1 = stable, deprecated; 2 = variable).
    uint256 private constant VARIABLE_RATE = 2;

    /// @notice The Aave v3 Pool, resolved from the addresses provider at construction. The single
    ///         call target for every market this adapter routes. All `encode*` functions return this
    ///         address as `target`.
    IPool public immutable pool;

    /// @notice The Aave v3 protocol data provider, resolved from the addresses provider at
    ///         construction. Used to read reserve token addresses and reserve configuration.
    IPoolDataProvider public immutable dataProvider;

    /// @notice Internal storage for the market allowlist and the owner guard.
    /// @param allowed The governed allowlist mapping `(collateral, debt)` to whether the pair is
    ///        routable. Managed via `setMarket`.
    /// @param owner The current adapter owner, gating `setMarket` and `transferOwnership`.
    struct AdapterStore {
        mapping(Currency collateral => mapping(Currency debt => bool)) allowed;
        Owner owner;
    }

    AdapterStore internal store;

    /// @dev Thrown when the addresses provider resolves the Pool or the data provider to the zero
    ///      address at construction.
    error ZeroAddress();

    /// @dev Thrown when `setMarket` is called to enable a pair whose collateral or debt asset is not
    ///      a live Aave reserve, and on any encode or read for an unrouted pair.
    /// @param collateral The collateral token of the unsupported market.
    /// @param debt The debt token of the unsupported market.
    error MarketNotSupported(Currency collateral, Currency debt);

    /// @notice Emitted when a market is enabled or disabled in the allowlist.
    /// @param collateral The collateral token address of the market.
    /// @param debt The debt token address of the market.
    /// @param allowed Whether the pair is now routable.
    event MarketSet(address indexed collateral, address indexed debt, bool allowed);

    /// @param provider The Aave v3 PoolAddressesProvider for the target market. The Pool and data
    ///        provider proxy addresses are resolved from it and stored immutably.
    /// @param owner_ The initial adapter owner (governance).
    constructor(IPoolAddressesProvider provider, address owner_) {
        address pool_ = provider.getPool();
        address dataProvider_ = provider.getPoolDataProvider();
        if (pool_ == address(0) || dataProvider_ == address(0)) revert ZeroAddress();
        pool = IPool(pool_);
        dataProvider = IPoolDataProvider(dataProvider_);
        store.owner.write(owner_);
    }

    /// @inheritdoc ILendingAdapter
    function lendingProtocol() external view returns (address) {
        return address(pool);
    }

    /// @inheritdoc ILendingAdapter
    function isSupportedMarket(Market calldata market) external view returns (bool) {
        return store.allowed[market.collateral][market.debt];
    }

    /// @inheritdoc ILendingAdapter
    /// @dev Encodes `IPool.supply` with `onBehalfOf = account` and referral code 0. The `value`
    ///      field is always 0 because the Aave Pool entrypoints used here are non-payable.
    function encodeSupplyCollateral(address account, Market calldata market, uint256 amount)
        external
        view
        returns (address, uint256, bytes memory)
    {
        _require(market);
        return
            (address(pool), 0, abi.encodeCall(IPool.supply, (Currency.unwrap(market.collateral), amount, account, 0)));
    }

    /// @inheritdoc ILendingAdapter
    /// @dev Encodes `IPool.withdraw` with `to = receiver`. Aave's withdraw honors the `to` recipient
    ///      directly, so the account does not need to forward. The `receiver` is validated by
    ///      `MarginAccount` before executing.
    function encodeWithdrawCollateral(address account, Market calldata market, uint256 amount, address receiver)
        external
        view
        returns (address, uint256, bytes memory)
    {
        _require(market);
        return
            (address(pool), 0, abi.encodeCall(IPool.withdraw, (Currency.unwrap(market.collateral), amount, receiver)));
    }

    /// @inheritdoc ILendingAdapter
    /// @dev Encodes `IPool.borrow` in variable-rate mode with `onBehalfOf = account`. Aave's borrow
    ///      has no receiver: the borrowed asset is delivered to the caller (the account), which
    ///      forwards it to the receiver it validates.
    function encodeBorrow(address account, Market calldata market, uint256 amount)
        external
        view
        returns (address, uint256, bytes memory)
    {
        _require(market);
        return (
            address(pool),
            0,
            abi.encodeCall(IPool.borrow, (Currency.unwrap(market.debt), amount, VARIABLE_RATE, 0, account))
        );
    }

    /// @inheritdoc ILendingAdapter
    /// @dev Encodes `IPool.repay` in variable-rate mode with `onBehalfOf = account`. Passing
    ///      `amount == type(uint256).max` repays the account's full variable debt natively,
    ///      including accrued interest, leaving no dust.
    function encodeRepay(address account, Market calldata market, uint256 amount)
        external
        view
        returns (address, uint256, bytes memory)
    {
        _require(market);
        return
            (address(pool), 0, abi.encodeCall(IPool.repay, (Currency.unwrap(market.debt), amount, VARIABLE_RATE, account)));
    }

    /// @inheritdoc ILendingAdapter
    /// @dev `collateralAmount` is the account's aToken balance for the collateral reserve and
    ///      `debtAmount` is its variable debt token balance for the debt reserve. Both Aave receipt
    ///      tokens rebase with accrued interest, so their `balanceOf` already reflects the current
    ///      obligation.
    function positionOf(address account, Market calldata market)
        external
        view
        returns (uint256 collateralAmount, uint256 debtAmount)
    {
        _require(market);
        (address aCollateral,,) = dataProvider.getReserveTokensAddresses(Currency.unwrap(market.collateral));
        (,, address vDebt) = dataProvider.getReserveTokensAddresses(Currency.unwrap(market.debt));
        collateralAmount = IERC20(aCollateral).balanceOf(account);
        debtAmount = IERC20(vDebt).balanceOf(account);
    }

    /// @inheritdoc ILendingAdapter
    /// @dev Reads the collateral reserve's liquidation threshold (the Aave analog of Morpho's
    ///      `lltv`), in basis points, and converts it to a WAD-scaled `Ltv`. Uses the liquidation
    ///      threshold, not the `ltv` (max-borrow) field.
    function maxLtvWad(Market calldata market) external view returns (Ltv) {
        _require(market);
        (,, uint256 liquidationThreshold,,,,,,,) =
            dataProvider.getReserveConfigurationData(Currency.unwrap(market.collateral));
        return toLtv(liquidationThreshold * WAD / BPS);
    }

    /// @inheritdoc ILendingAdapter
    /// @dev Computes the current LTV as `totalDebtBase * WAD / totalCollateralBase` from Aave's
    ///      account-level `getUserAccountData`, whose totals are denominated in the protocol's USD
    ///      base currency, so the collateral/debt decimal difference of a short needs no special
    ///      handling. Returns `type(uint256).max` (as an `Ltv`) when there is debt but zero
    ///      collateral, and 0 when there is no debt. This is account-level: it equals the position
    ///      LTV under the one-position-per-account assumption the router enforces.
    function currentLtvWad(address account, Market calldata market) external view returns (Ltv) {
        _require(market);
        (uint256 totalCollateralBase, uint256 totalDebtBase,,,,) = pool.getUserAccountData(account);
        if (totalCollateralBase == 0) return toLtv(totalDebtBase == 0 ? 0 : type(uint256).max);
        return toLtv(totalDebtBase * WAD / totalCollateralBase);
    }

    /// @notice The current adapter owner (governance). Only the owner may call `setMarket` and
    ///         `transferOwnership`.
    /// @return The current owner address.
    function owner() external view returns (address) {
        return store.owner.read();
    }

    /// @notice The address proposed to become owner, pending its acceptance. Zero when no handoff is
    ///         in progress.
    /// @return The pending owner address.
    function pendingOwner() external view returns (address) {
        return store.owner.pendingOwner();
    }

    /// @notice Completes an ownership handoff. Callable by anyone, but only the address previously
    ///         named by `transferOwnership` succeeds; all others revert. On success the caller
    ///         becomes the owner.
    function acceptOwnership() external {
        store.owner.acceptOwnership(msg.sender);
    }

    /// @notice Enables or disables routing for a `(collateral, debt)` pair. When enabling, both
    ///         assets must be live Aave reserves (their aToken addresses are non-zero). Owner-gated.
    /// @param collateral The collateral token of the pair.
    /// @param debt The debt token of the pair.
    /// @param allowed Whether the pair should be routable.
    function setMarket(Currency collateral, Currency debt, bool allowed) external {
        store.owner.onlyOwner(msg.sender);
        if (allowed) {
            (address aCollateral,,) = dataProvider.getReserveTokensAddresses(Currency.unwrap(collateral));
            (address aDebt,,) = dataProvider.getReserveTokensAddresses(Currency.unwrap(debt));
            if (aCollateral == address(0) || aDebt == address(0)) revert MarketNotSupported(collateral, debt);
        }
        store.allowed[collateral][debt] = allowed;
        emit MarketSet(Currency.unwrap(collateral), Currency.unwrap(debt), allowed);
    }

    /// @notice Begins a two-step ownership handoff by proposing a successor. The successor takes
    ///         effect only once it calls `acceptOwnership`; the current owner retains its powers
    ///         until then, and the zero address is rejected so the role cannot be bricked. Owner-gated.
    /// @param newOwner The address proposed to become the new owner.
    function transferOwnership(address newOwner) external {
        store.owner.onlyOwner(msg.sender);
        store.owner.propose(newOwner);
    }

    /// @notice Reverts `MarketNotSupported` unless the `(collateral, debt)` pair is allowlisted.
    /// @param market The market pair to check.
    function _require(Market calldata market) internal view {
        if (!store.allowed[market.collateral][market.debt]) {
            revert MarketNotSupported(market.collateral, market.debt);
        }
    }
}
