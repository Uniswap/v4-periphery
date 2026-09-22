// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IMorpho, IMorphoBase, MarketParams} from "morpho-blue/interfaces/IMorpho.sol";
import {IOracle} from "morpho-blue/interfaces/IOracle.sol";
import {MarketParamsLib} from "morpho-blue/libraries/MarketParamsLib.sol";
import {MorphoBalancesLib} from "morpho-blue/libraries/periphery/MorphoBalancesLib.sol";
import {Math} from "openzeppelin-contracts/contracts/utils/math/Math.sol";

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {ILendingAdapter} from "./interfaces/ILendingAdapter.sol";
import {PositionAmountResolver} from "./base/PositionAmountResolver.sol";
import {Market} from "./types/Market.sol";
import {Ltv, toLtv} from "./types/Ltv.sol";
import {PositionData} from "./types/PositionData.sol";

/// @title MorphoLendingAdapter
/// @author Uniswap Labs
/// @notice A singleton, stateless `ILendingAdapter` over every Morpho Blue market. The caller names
///         the market: `Market.data` is `abi.encode(address oracle, address irm, uint256 lltv)`, which
///         together with the `(collateral, debt)` pair is the full Morpho `MarketParams`. Every call
///         decodes the key and reverts `MarketNotSupported` unless that exact market exists on Morpho
///         Blue. Encoding and debt-accrual reads reuse Morpho Blue's own libraries; collateral
///         valuation, current LTV, and the health factor are derived locally from the market oracle's
///         price, mirroring Morpho's health formulas rather than delegating to them. Each encoded call
///         is executed by a `MarginAccount` as itself, so `onBehalf` is always the account and no
///         delegated authorization is needed.
/// @dev    Market selection is permissionless, so the caller vets the market it names (Morpho market
///         creation is itself permissionless: the oracle, IRM, and LLTV are whatever the creator
///         chose). Morpho Blue does not support fee-on-transfer or rebasing tokens, so a standard-ERC-20
///         market is what lets the router's flows net to zero with no residual; a non-standard token
///         fails the router's fill and settle assertions rather than leaving one.
/// @custom:security-contact security@uniswap.org
contract MorphoLendingAdapter is ILendingAdapter, PositionAmountResolver {
    using MarketParamsLib for MarketParams;
    using MorphoBalancesLib for IMorpho;

    // WAD scale for loan-to-value ratios.
    uint256 private constant WAD = 1e18;
    // Morpho oracle price scale: price() quotes 1 collateral asset in loan token, scaled by 1e36.
    uint256 private constant ORACLE_PRICE_SCALE = 1e36;
    // `Market.data` is abi.encode(address oracle, address irm, uint256 lltv): three words.
    uint256 private constant MARKET_DATA_LENGTH = 96;

    /// @notice The Morpho Blue singleton. The single call target for every market this adapter
    ///         routes. All `encode*` functions return this address as `target`.
    IMorpho public immutable morpho;

    /// @dev Thrown when constructed with a zero Morpho address, which would make every encode and
    ///      read revert opaquely.
    error ZeroAddress();

    /// @param morpho_ The Morpho Blue singleton this adapter routes to.
    constructor(IMorpho morpho_) {
        if (address(morpho_) == address(0)) revert ZeroAddress();
        morpho = morpho_;
    }

    /// @inheritdoc ILendingAdapter
    function lendingProtocol() external view returns (address) {
        return address(morpho);
    }

    /// @inheritdoc ILendingAdapter
    /// @dev True when `data` has the canonical shape and the `MarketParams` it completes is a created
    ///      market on Morpho Blue.
    function isSupportedMarket(Market calldata market) external view returns (bool) {
        if (market.data.length != MARKET_DATA_LENGTH) return false;
        return _exists(_params(market));
    }

    /// @inheritdoc ILendingAdapter
    /// @dev Resolves the key to `MarketParams`, then encodes `IMorphoBase.supplyCollateral` with
    ///      `onBehalf = account` and no callback data. The `value` field is always 0 because Morpho
    ///      Blue is non-payable.
    function encodeSupplyCollateral(address account, Market calldata market, uint256 amount)
        external
        view
        returns (address, uint256, bytes memory)
    {
        MarketParams memory marketParams = _resolve(market);
        return (address(morpho), 0, abi.encodeCall(IMorphoBase.supplyCollateral, (marketParams, amount, account, "")));
    }

    /// @inheritdoc ILendingAdapter
    /// @dev No-op: Morpho Blue treats supplied collateral as collateral automatically, so there is no
    ///      separate enable step. Returns empty `callData`, which the account skips, without decoding
    ///      the key: the account calls this only after `encodeSupplyCollateral` has validated it.
    function encodeEnableCollateral(address, Market calldata) external pure returns (address, uint256, bytes memory) {
        return (address(0), 0, "");
    }

    /// @inheritdoc ILendingAdapter
    /// @dev Encodes `IMorphoBase.withdrawCollateral` with `onBehalf = account` and
    ///      `receiver = receiver`. The `receiver` is validated by `MarginAccount` before executing.
    function encodeWithdrawCollateral(address account, Market calldata market, uint256 amount, address receiver)
        external
        view
        returns (address, uint256, bytes memory)
    {
        MarketParams memory marketParams = _resolve(market);
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
        MarketParams memory marketParams = _resolve(market);
        return (address(morpho), 0, abi.encodeCall(IMorphoBase.borrow, (marketParams, amount, 0, account, account)));
    }

    /// @inheritdoc ILendingAdapter
    /// @dev Repay routing with two guards for boundaries Morpho Blue would otherwise reject:
    ///      - A debt-free position (zero borrow shares) has nothing to repay, and Morpho rejects a
    ///        `(0 assets, 0 shares)` repay, so this returns empty `callData` the account skips. That
    ///        lets a generic "repay then withdraw" exit plan run against a position with no outstanding
    ///        debt (funded only via `addCollateral`, repaid out of band, or previously liquidated).
    ///      - A request at or above the reported debt (`type(uint256).max`, or `>= expectedBorrowAssets`,
    ///        the value `positionOf`/`describePosition` report) takes the share-based path, burning the
    ///        account's exact borrow shares. `expectedBorrowAssets` rounds up, so repaying it as assets
    ///        would convert to more shares than the account holds and underflow; the share path repays
    ///        in full with no interest dust.
    ///      A strictly partial repay encodes `IMorphoBase.repay` with `assets = amount`, `shares = 0`.
    function encodeRepay(address account, Market calldata market, uint256 amount)
        external
        view
        returns (address, uint256, bytes memory)
    {
        MarketParams memory marketParams = _resolve(market);
        uint256 shares = uint256(morpho.position(marketParams.id(), account).borrowShares);
        if (shares == 0) return (address(morpho), 0, "");
        if (amount == type(uint256).max || amount >= morpho.expectedBorrowAssets(marketParams, account)) {
            // full repay: burn the account's entire borrow share balance (assets resolved by Morpho)
            return (address(morpho), 0, abi.encodeCall(IMorphoBase.repay, (marketParams, 0, shares, account, "")));
        }
        return (address(morpho), 0, abi.encodeCall(IMorphoBase.repay, (marketParams, amount, 0, account, "")));
    }

    /// @inheritdoc ILendingAdapter
    /// @dev `collateralAmount` is read from the raw `position.collateral` field (no accrual needed
    ///      for collateral). `debtAmount` uses `MorphoBalancesLib.expectedBorrowAssets`, which
    ///      applies interest accrual to give the current obligation rather than the stale stored
    ///      value.
    function positionOf(address account, Market memory market)
        public
        view
        override(ILendingAdapter, PositionAmountResolver)
        returns (uint256 collateralAmount, uint256 debtAmount)
    {
        MarketParams memory marketParams = _resolve(market);
        collateralAmount = uint256(morpho.position(marketParams.id(), account).collateral);
        debtAmount = morpho.expectedBorrowAssets(marketParams, account);
    }

    /// @inheritdoc ILendingAdapter
    /// @dev Reads the market's `lltv` field (already a WAD from Morpho Blue) and wraps it as an
    ///      `Ltv` type.
    function maxLtvWad(Market calldata market) external view returns (Ltv) {
        return toLtv(_resolve(market).lltv);
    }

    /// @inheritdoc ILendingAdapter
    /// @dev Computes the current LTV as `debt * WAD / collateralValue`, where `collateralValue` is
    ///      the oracle's price of collateral quoted in the loan token (1e36-scaled). Returns
    ///      `type(uint256).max` (as an `Ltv`) when there is debt but zero collateral value (fully
    ///      undercollateralized). Returns 0 when there is no debt.
    function currentLtvWad(address account, Market calldata market) external view returns (Ltv) {
        MarketParams memory marketParams = _resolve(market);
        (, uint256 debt, uint256 collateralValue) = _positionValues(marketParams, account);
        return _ltv(debt, collateralValue);
    }

    /// @inheritdoc ILendingAdapter
    /// @dev Reads the account's position once and derives every field from it, so an integrator can
    ///      compose a position view without separate `positionOf`/`maxLtvWad`/`currentLtvWad` calls.
    ///      Health factor is `lltv * collateralValue / debt` (WAD), i.e. `maxLtv / currentLtv`, and is
    ///      `type(uint256).max` when there is no debt and 0 when debt exists against no collateral
    ///      value.
    function describePosition(address account, Market calldata market)
        external
        view
        returns (PositionData memory data)
    {
        MarketParams memory marketParams = _resolve(market);
        (uint256 collateral, uint256 debt, uint256 collateralValue) = _positionValues(marketParams, account);
        data = PositionData({
            collateralAmount: collateral,
            debtAmount: debt,
            maxLtv: toLtv(marketParams.lltv),
            currentLtv: _ltv(debt, collateralValue),
            // maxLtv / currentLtv == lltv * collateralValue / debt (WAD); mulDiv keeps full precision
            healthFactorWad: debt == 0 ? type(uint256).max : Math.mulDiv(collateralValue, marketParams.lltv, debt)
        });
    }

    /// @notice Reads the account's collateral, accrued debt, and oracle-priced collateral value (in
    ///         loan-token units) for an already-resolved market.
    /// @param marketParams The resolved Morpho market parameters.
    /// @param account The account to read.
    /// @return collateral The account's supplied collateral, in the collateral token's native decimals.
    /// @return debt The account's debt with accrued interest, in the loan token's native decimals.
    /// @return collateralValue The collateral valued in loan-token units via the market oracle.
    function _positionValues(MarketParams memory marketParams, address account)
        internal
        view
        returns (uint256 collateral, uint256 debt, uint256 collateralValue)
    {
        collateral = uint256(morpho.position(marketParams.id(), account).collateral);
        debt = morpho.expectedBorrowAssets(marketParams, account);
        // price() is 1e36-scaled, so mulDiv keeps the collateral * price product in full 512-bit
        // precision and avoids a phantom-overflow revert.
        collateralValue = Math.mulDiv(collateral, IOracle(marketParams.oracle).price(), ORACLE_PRICE_SCALE);
    }

    /// @notice Current LTV from accrued debt and oracle-priced collateral value. `type(uint256).max`
    ///         when there is debt but no collateral value (fully undercollateralized); zero when
    ///         there is no debt.
    /// @param debt The account's debt with accrued interest.
    /// @param collateralValue The collateral valued in loan-token units.
    /// @return The current LTV as an `Ltv` (WAD, 1e18 == 100%).
    function _ltv(uint256 debt, uint256 collateralValue) internal pure returns (Ltv) {
        if (collateralValue == 0) return toLtv(debt == 0 ? 0 : type(uint256).max);
        return toLtv(debt * WAD / collateralValue);
    }

    /// @notice Resolves a market key to the Morpho `MarketParams` it names, reverting unless the
    ///         market exists on Morpho Blue. `InvalidMarketData` for `data` of the wrong shape,
    ///         `MarketNotSupported` for a market Morpho has not created.
    /// @param market The market key to resolve.
    /// @return marketParams The Morpho market parameters.
    function _resolve(Market memory market) internal view returns (MarketParams memory marketParams) {
        if (market.data.length != MARKET_DATA_LENGTH) revert InvalidMarketData(market.data.length);
        marketParams = _params(market);
        if (!_exists(marketParams)) revert MarketNotSupported(market.collateral, market.debt);
    }

    /// @notice Decodes a market key into `MarketParams` without checking the market exists. The
    ///         caller checks `data.length` first, so `abi.decode` cannot revert here.
    /// @param market The market key to decode.
    /// @return The Morpho market parameters the key describes.
    function _params(Market memory market) internal pure returns (MarketParams memory) {
        (address oracle, address irm, uint256 lltv) = abi.decode(market.data, (address, address, uint256));
        return MarketParams({
            loanToken: Currency.unwrap(market.debt),
            collateralToken: Currency.unwrap(market.collateral),
            oracle: oracle,
            irm: irm,
            lltv: lltv
        });
    }

    /// @notice Whether Morpho Blue has created the market with exactly these parameters. The market
    ///         id is the hash of the full `MarketParams`, so a stored non-zero loan token for that id
    ///         proves every field of the key matches a live market.
    /// @param marketParams The market parameters to look up.
    /// @return True if the market exists on Morpho Blue.
    function _exists(MarketParams memory marketParams) internal view returns (bool) {
        return morpho.idToMarketParams(marketParams.id()).loanToken != address(0);
    }
}
