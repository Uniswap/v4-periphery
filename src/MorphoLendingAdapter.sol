// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IMorpho, IMorphoBase, MarketParams, Id, Position} from "morpho-blue/interfaces/IMorpho.sol";
import {IOracle} from "morpho-blue/interfaces/IOracle.sol";
import {MarketParamsLib} from "morpho-blue/libraries/MarketParamsLib.sol";
import {MorphoBalancesLib} from "morpho-blue/libraries/periphery/MorphoBalancesLib.sol";

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {ILendingAdapter} from "./interfaces/ILendingAdapter.sol";
import {Market} from "./types/Market.sol";
import {MarketRegistry} from "./types/MarketRegistry.sol";
import {Owner} from "./types/Owner.sol";
import {Ltv, toLtv} from "./types/Ltv.sol";

/// @title MorphoLendingAdapter
/// @author Uniswap Labs
/// @notice A singleton `ILendingAdapter` over all curated Morpho Blue markets. The adapter is a
///         thin shell composing a governed `(collateral, debt)` routing table and an owner guard;
///         all encode and read logic reuses Morpho Blue's own libraries, so no Morpho math is
///         reimplemented. Each encoded call is executed by a `MarginAccount` as itself, so
///         `onBehalf` is always the account and no delegated authorization is needed.
/// @custom:security-contact security@uniswap.org
contract MorphoLendingAdapter is ILendingAdapter {
    using MarketParamsLib for MarketParams;
    using MorphoBalancesLib for IMorpho;

    // WAD scale for loan-to-value ratios.
    uint256 private constant WAD = 1e18;
    // Morpho oracle price scale: price() quotes 1 collateral asset in loan token, scaled by 1e36.
    uint256 private constant ORACLE_PRICE_SCALE = 1e36;

    /// @notice The Morpho Blue singleton. The single call target for every market this adapter
    ///         routes. All `encode*` functions return this address as `target`.
    IMorpho public immutable morpho;

    /// @notice Internal storage for the market routing table and the owner guard.
    /// @param markets The governed routing table mapping `(collateral, debt)` to Morpho
    ///        `MarketParams`. Managed via `register`, `resolve`, and `isSupported` free functions
    ///        from `MarketRegistry`.
    /// @param owner The current adapter owner, gating `setMarket` and `transferOwnership`.
    struct AdapterStore {
        MarketRegistry markets;
        Owner owner;
    }

    AdapterStore internal store;

    /// @dev Thrown when `setMarket` is called with a `MarketParams` whose `id()` does not exist on
    ///      Morpho Blue. Prevents routing to a market that cannot be interacted with.
    error MorphoMarketNotCreated();

    /// @notice Emitted when a market is registered or replaced in the routing table. Includes
    ///         oracle, IRM, and LLTV so offchain monitoring can vet the routed market configuration.
    /// @param collateral The collateral token address of the registered market.
    /// @param debt The debt (loan) token address of the registered market.
    /// @param id The Morpho Blue market id derived from the `MarketParams`.
    /// @param oracle The price oracle address for this Morpho market.
    /// @param irm The interest rate model address for this Morpho market.
    /// @param lltv The liquidation LTV for this Morpho market (WAD, 1e18 == 100%).
    event MarketSet(address indexed collateral, address indexed debt, Id id, address oracle, address irm, uint256 lltv);

    constructor(IMorpho morpho_, address owner_) {
        morpho = morpho_;
        store.owner.write(owner_);
    }

    /// @inheritdoc ILendingAdapter
    function lendingProtocol() external view returns (address) {
        return address(morpho);
    }

    /// @inheritdoc ILendingAdapter
    function isSupportedMarket(Market calldata market) external view returns (bool) {
        return store.markets.isSupported(market);
    }

    /// @inheritdoc ILendingAdapter
    /// @dev Resolves the market pair to `MarketParams`, then encodes `IMorphoBase.supplyCollateral`
    ///      with `onBehalf = account` and no callback data. The `value` field is always 0 because
    ///      Morpho Blue is non-payable.
    function encodeSupplyCollateral(address account, Market calldata market, uint256 amount)
        external
        view
        returns (address, uint256, bytes memory)
    {
        MarketParams memory marketParams = store.markets.resolve(market);
        bytes memory data;
        return (address(morpho), 0, abi.encodeCall(IMorphoBase.supplyCollateral, (marketParams, amount, account, data)));
    }

    /// @inheritdoc ILendingAdapter
    /// @dev Encodes `IMorphoBase.withdrawCollateral` with `onBehalf = account` and
    ///      `receiver = receiver`. The `receiver` is validated by `MarginAccount` before executing.
    function encodeWithdrawCollateral(address account, Market calldata market, uint256 amount, address receiver)
        external
        view
        returns (address, uint256, bytes memory)
    {
        MarketParams memory marketParams = store.markets.resolve(market);
        return
            (
                address(morpho),
                0,
                abi.encodeCall(IMorphoBase.withdrawCollateral, (marketParams, amount, account, receiver))
            );
    }

    /// @inheritdoc ILendingAdapter
    /// @dev Encodes `IMorphoBase.borrow` with `assets = amount`, `shares = 0` (asset-denominated),
    ///      `onBehalf = account`, and `receiver = account`. The borrowed asset is delivered to the
    ///      account, which forwards it to the receiver it validates.
    function encodeBorrow(address account, Market calldata market, uint256 amount)
        external
        view
        returns (address, uint256, bytes memory)
    {
        MarketParams memory marketParams = store.markets.resolve(market);
        return (address(morpho), 0, abi.encodeCall(IMorphoBase.borrow, (marketParams, amount, 0, account, account)));
    }

    /// @inheritdoc ILendingAdapter
    /// @dev When `amount == type(uint256).max`, encodes a share-based full repay by reading the
    ///      account's current `borrowShares` from `morpho.position`. This avoids the interest dust
    ///      that asset-denominated rounding leaves behind. For partial repays, encodes
    ///      `IMorphoBase.repay` with `assets = amount` and `shares = 0`.
    function encodeRepay(address account, Market calldata market, uint256 amount)
        external
        view
        returns (address, uint256, bytes memory)
    {
        MarketParams memory marketParams = store.markets.resolve(market);
        bytes memory data;
        if (amount == type(uint256).max) {
            // full repay: burn the account's entire borrow share balance (assets resolved by Morpho)
            uint256 shares = uint256(morpho.position(marketParams.id(), account).borrowShares);
            return (address(morpho), 0, abi.encodeCall(IMorphoBase.repay, (marketParams, 0, shares, account, data)));
        }
        return (address(morpho), 0, abi.encodeCall(IMorphoBase.repay, (marketParams, amount, 0, account, data)));
    }

    /// @inheritdoc ILendingAdapter
    /// @dev `collateralAmount` is read from the raw `position.collateral` field (no accrual needed
    ///      for collateral). `debtAmount` uses `MorphoBalancesLib.expectedBorrowAssets`, which
    ///      applies interest accrual to give the current obligation rather than the stale stored
    ///      value.
    function positionOf(address account, Market calldata market)
        external
        view
        returns (uint256 collateralAmount, uint256 debtAmount)
    {
        MarketParams memory marketParams = store.markets.resolve(market);
        collateralAmount = uint256(morpho.position(marketParams.id(), account).collateral);
        debtAmount = morpho.expectedBorrowAssets(marketParams, account);
    }

    /// @inheritdoc ILendingAdapter
    /// @dev Reads the market's `lltv` field (already a WAD from Morpho Blue) and wraps it as an
    ///      `Ltv` type.
    function maxLtvWad(Market calldata market) external view returns (Ltv) {
        return toLtv(store.markets.resolve(market).lltv);
    }

    /// @inheritdoc ILendingAdapter
    /// @dev Computes the current LTV as `debt * WAD / collateralValue`, where `collateralValue` is
    ///      the oracle's price of collateral quoted in the loan token (1e36-scaled). Returns
    ///      `type(uint256).max` (as an `Ltv`) when there is debt but zero collateral value (fully
    ///      undercollateralized). Returns 0 when there is no debt.
    function currentLtvWad(address account, Market calldata market) external view returns (Ltv) {
        MarketParams memory marketParams = store.markets.resolve(market);
        uint256 collateral = uint256(morpho.position(marketParams.id(), account).collateral);
        uint256 debt = morpho.expectedBorrowAssets(marketParams, account);
        // collateral value expressed in loan-token units
        uint256 collateralValue = collateral * IOracle(marketParams.oracle).price() / ORACLE_PRICE_SCALE;
        if (collateralValue == 0) return toLtv(debt == 0 ? 0 : type(uint256).max);
        return toLtv(debt * WAD / collateralValue);
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

    /// @notice Registers or replaces the canonical Morpho Blue market for its `(collateral, debt)`
    ///         pair. The market must already exist on Morpho Blue (verified by checking that
    ///         `idToMarketParams(id).loanToken` is non-zero). Owner-gated.
    /// @param marketParams The Morpho Blue `MarketParams` to register. Its `collateralToken` and
    ///        `loanToken` fields determine the routing key.
    function setMarket(MarketParams calldata marketParams) external {
        store.owner.onlyOwner(msg.sender);
        Id id = marketParams.id();
        if (morpho.idToMarketParams(id).loanToken == address(0)) revert MorphoMarketNotCreated();
        store.markets.register(marketParams);
        emit MarketSet(
            marketParams.collateralToken,
            marketParams.loanToken,
            id,
            marketParams.oracle,
            marketParams.irm,
            marketParams.lltv
        );
    }

    /// @notice Begins a two-step ownership handoff by proposing a successor. The successor takes
    ///         effect only once it calls `acceptOwnership`; the current owner retains its powers
    ///         until then, and the zero address is rejected so the role cannot be bricked. Owner-gated.
    /// @param newOwner The address proposed to become the new owner.
    function transferOwnership(address newOwner) external {
        store.owner.onlyOwner(msg.sender);
        store.owner.propose(newOwner);
    }
}
