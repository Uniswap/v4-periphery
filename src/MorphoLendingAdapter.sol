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

/// @notice A singleton ILendingAdapter over all curated Morpho Blue markets. The adapter is a thin
///         shell composing a governed (collateral, debt) routing table and an owner guard; all
///         encode and read logic reuses morpho-blue's own libraries, so no Morpho math is
///         reimplemented. Each encoded call is executed by a MarginAccount as itself, so onBehalf is
///         always the account and no delegated authorization is needed.
contract MorphoLendingAdapter is ILendingAdapter {
    using MarketParamsLib for MarketParams;
    using MorphoBalancesLib for IMorpho;

    // WAD scale for loan-to-value ratios.
    uint256 private constant WAD = 1e18;
    // Morpho oracle price scale: price() quotes 1 collateral asset in loan token, scaled by 1e36.
    uint256 private constant ORACLE_PRICE_SCALE = 1e36;

    /// @notice The Morpho Blue singleton. The single call target for every routed market.
    IMorpho public immutable morpho;

    struct AdapterStore {
        MarketRegistry markets;
        Owner owner;
    }

    AdapterStore internal store;

    /// @notice Thrown when registering a market that does not exist on Morpho.
    error MorphoMarketNotCreated();

    /// @notice Emitted when a market is registered or replaced in the routing table. Includes the
    ///         oracle, irm, and lltv so offchain monitoring can vet the routed market.
    event MarketSet(address indexed collateral, address indexed debt, Id id, address oracle, address irm, uint256 lltv);

    constructor(IMorpho morpho_, address owner_) {
        morpho = morpho_;
        store.owner.write(owner_);
    }

    /// @notice The current adapter owner (governance).
    function owner() external view returns (address) {
        return store.owner.read();
    }

    /// @notice Transfers adapter ownership. Owner-gated.
    function transferOwnership(address newOwner) external {
        store.owner.onlyOwner(msg.sender);
        store.owner.write(newOwner);
    }

    /// @notice Registers or replaces the canonical Morpho market for its (collateral, debt) pair.
    ///         Owner-gated, and requires the market to already exist on Morpho.
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

    /// @inheritdoc ILendingAdapter
    function lendingProtocol() external view returns (address) {
        return address(morpho);
    }

    /// @inheritdoc ILendingAdapter
    function isSupportedMarket(Market calldata market) external view returns (bool) {
        return store.markets.isSupported(market);
    }

    /// @inheritdoc ILendingAdapter
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
    function encodeWithdrawCollateral(address account, Market calldata market, uint256 amount, address receiver)
        external
        view
        returns (address, uint256, bytes memory)
    {
        MarketParams memory marketParams = store.markets.resolve(market);
        return
            (address(morpho), 0, abi.encodeCall(IMorphoBase.withdrawCollateral, (marketParams, amount, account, receiver)));
    }

    /// @inheritdoc ILendingAdapter
    function encodeBorrow(address account, Market calldata market, uint256 amount, address receiver)
        external
        view
        returns (address, uint256, bytes memory)
    {
        MarketParams memory marketParams = store.markets.resolve(market);
        return (address(morpho), 0, abi.encodeCall(IMorphoBase.borrow, (marketParams, amount, 0, account, receiver)));
    }

    /// @inheritdoc ILendingAdapter
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
    function maxLtvWad(Market calldata market) external view returns (Ltv) {
        return toLtv(store.markets.resolve(market).lltv);
    }

    /// @inheritdoc ILendingAdapter
    function currentLtvWad(address account, Market calldata market) external view returns (Ltv) {
        MarketParams memory marketParams = store.markets.resolve(market);
        uint256 collateral = uint256(morpho.position(marketParams.id(), account).collateral);
        uint256 debt = morpho.expectedBorrowAssets(marketParams, account);
        // collateral value expressed in loan-token units
        uint256 collateralValue = collateral * IOracle(marketParams.oracle).price() / ORACLE_PRICE_SCALE;
        if (collateralValue == 0) return toLtv(debt == 0 ? 0 : type(uint256).max);
        return toLtv(debt * WAD / collateralValue);
    }
}
