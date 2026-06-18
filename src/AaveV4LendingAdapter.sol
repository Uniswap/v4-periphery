// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Math} from "openzeppelin-contracts/contracts/utils/math/Math.sol";

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {ILendingAdapter} from "./interfaces/ILendingAdapter.sol";
import {ISpoke} from "./interfaces/external/aave-v4/ISpoke.sol";
import {OwnableAdapter} from "./base/OwnableAdapter.sol";
import {Market} from "./types/Market.sol";
import {Ltv, toLtv} from "./types/Ltv.sol";

/// @title AaveV4LendingAdapter
/// @author Uniswap Labs
/// @notice A singleton `ILendingAdapter` over a single Aave v4 Spoke. The adapter is a thin shell
///         composing a governed `(collateral, debt)` route registry and an owner guard; all encode
///         and read logic delegates to the Spoke, so no Aave math is reimplemented. Each encoded call
///         is executed by a `MarginAccount` as itself, so the Aave `onBehalfOf` is always the account
///         and no delegated authorization is needed. The motivating use case is a short ETH position:
///         supply USDC as collateral and borrow WETH.
/// @dev    Design and trust notes:
///         - Aave v4 is hub-and-spoke. A market is keyed by a per-Spoke `reserveId`, not an asset
///           address, so the route registry maps each `(collateral, debt)` pair to its
///           `(collateralReserveId, debtReserveId)` on the bound Spoke. The Spoke is held immutably
///           and is the single call target for every market this adapter routes; to serve a second
///           Spoke, deploy a second adapter instance and allowlist it on the router.
///         - The account acts as its own `onBehalfOf` AND is the direct caller, so
///           `Spoke._isPositionManager(account, account)` short-circuits to true. The v4 position
///           manager / intent apparatus (for third-party relayers) is therefore irrelevant here.
///         - v4 `supply` does NOT auto-enable collateral, so `encodeSupplyCollateral` batches
///           `supply` and `setUsingAsCollateral` in a `Spoke.multicall` (a delegatecall-to-self that
///           preserves `msg.sender`, so the inner supply pulls the underlying against the account's
///           allowance to the Spoke). `setUsingAsCollateral` is idempotent, so re-emitting it on every
///           supply is safe.
///         - v4 `borrow` and `withdraw` deliver the underlying to `msg.sender` (the account). The
///           account holds the funds and forwards them to its validated receiver, so neither encoder
///           carries a recipient.
///         - debt is the sum of drawn debt and accrued premium; `positionOf` and full repay both read
///           `getUserTotalDebt`, and the router's close swap is sized off that premium-inclusive debt.
///         - `maxLtvWad` reads the collateral reserve's `collateralFactor` (the closest analog of
///           Aave v3's liquidation threshold). v4's true liquidation point also depends on the
///           position's risk premium and dynamic config; `healthFactor < 1e18` is the authoritative
///           liquidation signal.
///         - `currentLtvWad` and `positionOf` read the Spoke's ACCOUNT-LEVEL state (the Spoke tracks
///           health across the whole account, not per `(collateral, debt)` pair), so they equal the
///           position's values only when the account holds a single position on this Spoke. This is a
///           USAGE REQUIREMENT, not a router-enforced invariant: each Spoke position must use its own
///           `(owner, subId)` account. Co-locating two of this Spoke's markets under one `subId` blends
///           the reads and can make a close/decrease revert or withdraw collateral still backing
///           another debt. Use a distinct `subId` per Spoke position.
///         - Routing is curated: every `encode*` and read reverts `MarketNotSupported` for a pair the
///           owner has not registered, never returning a silent default market.
/// @custom:security-contact security@uniswap.org
contract AaveV4LendingAdapter is ILendingAdapter, OwnableAdapter {
    // WAD scale for loan-to-value ratios (1e18 == 100%).
    uint256 private constant WAD = 1e18;
    // Aave expresses collateral factors in basis points (1e4 == 100%).
    uint256 private constant BPS = 1e4;
    // RAY scale: v4 reports total debt value scaled by RAY (1e27).
    uint256 private constant RAY = 1e27;

    /// @notice The Aave v4 Spoke this adapter routes to. The single call target for every market;
    ///         all `encode*` functions return this address as `target` and `lendingProtocol()`
    ///         returns it.
    ISpoke public immutable spoke;

    /// @notice A resolved market route on the bound Spoke.
    /// @param collateralReserveId The reserve identifier of the collateral asset.
    /// @param debtReserveId The reserve identifier of the debt asset.
    /// @param registered Whether the route is enabled.
    struct V4MarketRoute {
        uint256 collateralReserveId;
        uint256 debtReserveId;
        bool registered;
    }

    /// @notice Internal storage for the market route registry. The owner guard lives in
    ///         `OwnableAdapter`.
    /// @param routes The governed mapping from `(collateral, debt)` to its reserve-id route. Managed
    ///        via `setMarket`.
    struct AdapterStore {
        mapping(Currency collateral => mapping(Currency debt => V4MarketRoute)) routes;
    }

    AdapterStore internal store;

    /// @dev Thrown when the Spoke is the zero address at construction.
    error ZeroAddress();

    /// @dev Thrown on any encode or read for a `(collateral, debt)` pair that is not registered.
    /// @param collateral The collateral token of the unsupported market.
    /// @param debt The debt token of the unsupported market.
    error MarketNotSupported(Currency collateral, Currency debt);

    /// @dev Thrown when `encodeWithdrawCollateral` is called with an `account` that is not the caller.
    ///      v4 withdraw delivers the underlying to `msg.sender`, so the encoder only ever produces a
    ///      withdrawal for the account that calls it.
    /// @param account The account argument supplied to the encoder.
    /// @param caller The actual caller (`msg.sender`).
    error AccountMismatch(address account, address caller);

    /// @dev Thrown by `setMarket` when a reserve's on-chain underlying does not match the currency it
    ///      is being registered for, guarding against a mis-typed reserve id.
    /// @param reserveId The reserve identifier checked.
    /// @param actualUnderlying The underlying the Spoke reports for the reserve.
    /// @param expectedUnderlying The currency the reserve is being registered for.
    error ReserveMismatch(uint256 reserveId, address actualUnderlying, address expectedUnderlying);

    /// @dev Thrown by `setMarket` when the collateral and debt reserves are on different Hubs, which a
    ///      single v4 position cannot span.
    /// @param collateralHub The Hub of the collateral reserve.
    /// @param debtHub The Hub of the debt reserve.
    error HubMismatch(address collateralHub, address debtHub);

    /// @notice Emitted when a market route is enabled or disabled.
    /// @param collateral The collateral token address of the market.
    /// @param debt The debt token address of the market.
    /// @param collateralReserveId The collateral reserve identifier on the Spoke.
    /// @param debtReserveId The debt reserve identifier on the Spoke.
    /// @param allowed Whether the pair is now routable.
    event MarketSet(
        address indexed collateral,
        address indexed debt,
        uint256 collateralReserveId,
        uint256 debtReserveId,
        bool allowed
    );

    /// @param spoke_ The Aave v4 Spoke this adapter routes to.
    /// @param owner_ The initial adapter owner (governance).
    constructor(ISpoke spoke_, address owner_) OwnableAdapter(owner_) {
        if (address(spoke_) == address(0)) revert ZeroAddress();
        spoke = spoke_;
    }

    /// @inheritdoc ILendingAdapter
    function lendingProtocol() external view returns (address) {
        return address(spoke);
    }

    /// @inheritdoc ILendingAdapter
    function isSupportedMarket(Market calldata market) external view returns (bool) {
        return store.routes[market.collateral][market.debt].registered;
    }

    /// @inheritdoc ILendingAdapter
    /// @dev v4 `supply` does not auto-enable collateral, so the encoded call is a `Spoke.multicall`
    ///      batching `supply(collateralReserveId, amount, account)` and
    ///      `setUsingAsCollateral(collateralReserveId, true, account)`. The multicall delegatecalls to
    ///      self, so the inner supply observes `msg.sender == account` and pulls the underlying against
    ///      the account's allowance to the Spoke. `value` is 0 (the Spoke is non-payable).
    function encodeSupplyCollateral(address account, Market calldata market, uint256 amount)
        external
        view
        returns (address, uint256, bytes memory)
    {
        V4MarketRoute storage route = _resolveRoute(market);
        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeCall(ISpoke.supply, (route.collateralReserveId, amount, account));
        calls[1] = abi.encodeCall(ISpoke.setUsingAsCollateral, (route.collateralReserveId, true, account));
        return (address(spoke), 0, abi.encodeCall(ISpoke.multicall, (calls)));
    }

    /// @inheritdoc ILendingAdapter
    /// @dev Encodes `Spoke.withdraw(collateralReserveId, amount, account)`. v4 withdraw delivers the
    ///      underlying to `msg.sender` (the account); the `receiver` is ignored here and the account
    ///      forwards the withdrawn underlying to its validated recipient. `account` must be the caller,
    ///      binding the otherwise-unused parameter and asserting the encoder only produces a withdrawal
    ///      for the account that calls it (the `MarginAccount` always passes its own address).
    function encodeWithdrawCollateral(address account, Market calldata market, uint256 amount, address)
        external
        view
        returns (address, uint256, bytes memory)
    {
        V4MarketRoute storage route = _resolveRoute(market);
        if (account != msg.sender) revert AccountMismatch(account, msg.sender);
        return (address(spoke), 0, abi.encodeCall(ISpoke.withdraw, (route.collateralReserveId, amount, account)));
    }

    /// @inheritdoc ILendingAdapter
    /// @dev Encodes `Spoke.borrow(debtReserveId, amount, account)`. v4 borrow delivers the underlying
    ///      to `msg.sender` (the account), which forwards it to the receiver it validates; there is no
    ///      receiver parameter on the protocol call.
    function encodeBorrow(address account, Market calldata market, uint256 amount)
        external
        view
        returns (address, uint256, bytes memory)
    {
        V4MarketRoute storage route = _resolveRoute(market);
        return (address(spoke), 0, abi.encodeCall(ISpoke.borrow, (route.debtReserveId, amount, account)));
    }

    /// @inheritdoc ILendingAdapter
    /// @dev Encodes `Spoke.repay(debtReserveId, amount, account)`. Passing `amount == type(uint256).max`
    ///      repays the account's full debt: the Spoke caps an over-amount to the total debt (drawn plus
    ///      premium), leaving no dust. The max-uint cap applies on the Spoke directly, which is what the
    ///      account calls.
    function encodeRepay(address account, Market calldata market, uint256 amount)
        external
        view
        returns (address, uint256, bytes memory)
    {
        V4MarketRoute storage route = _resolveRoute(market);
        return (address(spoke), 0, abi.encodeCall(ISpoke.repay, (route.debtReserveId, amount, account)));
    }

    /// @inheritdoc ILendingAdapter
    /// @dev `collateralAmount` is the account's supplied underlying for the collateral reserve and
    ///      `debtAmount` is its total debt (drawn plus accrued premium) for the debt reserve. Both are
    ///      asset-denominated and already reflect accrued interest.
    function positionOf(address account, Market calldata market)
        external
        view
        returns (uint256 collateralAmount, uint256 debtAmount)
    {
        V4MarketRoute storage route = _resolveRoute(market);
        collateralAmount = spoke.getUserSuppliedAssets(route.collateralReserveId, account);
        debtAmount = spoke.getUserTotalDebt(route.debtReserveId, account);
    }

    /// @inheritdoc ILendingAdapter
    /// @dev Reads the collateral reserve's `collateralFactor` (basis points) from its current dynamic
    ///      config and converts it to a WAD-scaled `Ltv`. This is the closest analog of Aave v3's
    ///      liquidation threshold; v4's true liquidation point also depends on the position's risk
    ///      premium and dynamic config, and `healthFactor < 1e18` is the authoritative signal.
    function maxLtvWad(Market calldata market) external view returns (Ltv) {
        V4MarketRoute storage route = _resolveRoute(market);
        ISpoke.Reserve memory reserve = spoke.getReserve(route.collateralReserveId);
        ISpoke.DynamicReserveConfig memory dynamicConfig =
            spoke.getDynamicReserveConfig(route.collateralReserveId, reserve.dynamicConfigKey);
        return toLtv(uint256(dynamicConfig.collateralFactor) * WAD / BPS);
    }

    /// @inheritdoc ILendingAdapter
    /// @dev Computes the current LTV from the Spoke's account-level data. `totalCollateralValue` is in
    ///      Value units (USD scaled by the oracle decimals) and `totalDebtValueRay` is the same Value
    ///      units additionally scaled by RAY, so the WAD LTV is
    ///      `totalDebtValueRay * WAD / (totalCollateralValue * RAY)`. Returns `type(uint256).max` (as
    ///      an `Ltv`) when there is debt but zero collateral, and 0 when there is no debt. This is
    ///      ACCOUNT-LEVEL (Spoke-scoped): it equals the position LTV only when the account holds a
    ///      single position on this Spoke. Co-locating multiple Spoke markets under one `(owner, subId)`
    ///      blends every reserve into these totals. The router does NOT enforce one position per
    ///      account; callers must use a distinct `subId` per Spoke position.
    /// @param market Must be a registered pair (only the route gates the call; the account's full
    ///        Spoke position determines the totals).
    function currentLtvWad(address account, Market calldata market) external view returns (Ltv) {
        _resolveRoute(market);
        ISpoke.UserAccountData memory data = spoke.getUserAccountData(account);
        if (data.totalDebtValueRay == 0) return toLtv(0);
        if (data.totalCollateralValue == 0) return toLtv(type(uint256).max);
        return toLtv(Math.mulDiv(data.totalDebtValueRay, WAD, data.totalCollateralValue * RAY));
    }

    /// @notice Enables or disables routing for a `(collateral, debt)` pair on the bound Spoke. When
    ///         enabling, both reserves are validated on-chain: each reserve's `underlying` must match
    ///         the currency it is registered for, and both reserves must be on the same Hub. Owner-gated.
    /// @param collateral The collateral token of the pair.
    /// @param debt The debt token of the pair.
    /// @param collateralReserveId The collateral reserve identifier on the Spoke.
    /// @param debtReserveId The debt reserve identifier on the Spoke.
    /// @param allowed Whether the pair should be routable.
    function setMarket(
        Currency collateral,
        Currency debt,
        uint256 collateralReserveId,
        uint256 debtReserveId,
        bool allowed
    ) external {
        _onlyOwner();
        if (allowed) {
            ISpoke.Reserve memory collateralReserve = spoke.getReserve(collateralReserveId);
            ISpoke.Reserve memory debtReserve = spoke.getReserve(debtReserveId);
            if (collateralReserve.underlying != Currency.unwrap(collateral)) {
                revert ReserveMismatch(collateralReserveId, collateralReserve.underlying, Currency.unwrap(collateral));
            }
            if (debtReserve.underlying != Currency.unwrap(debt)) {
                revert ReserveMismatch(debtReserveId, debtReserve.underlying, Currency.unwrap(debt));
            }
            if (collateralReserve.hub != debtReserve.hub) {
                revert HubMismatch(collateralReserve.hub, debtReserve.hub);
            }
            store.routes[collateral][debt] = V4MarketRoute({
                collateralReserveId: collateralReserveId, debtReserveId: debtReserveId, registered: true
            });
        } else {
            delete store.routes[collateral][debt];
        }
        emit MarketSet(Currency.unwrap(collateral), Currency.unwrap(debt), collateralReserveId, debtReserveId, allowed);
    }

    /// @notice Reverts `MarketNotSupported` unless the `(collateral, debt)` pair is registered, and
    ///         returns its route for reuse by the caller.
    /// @param market The market pair to resolve.
    /// @return route The resolved route for the pair.
    function _resolveRoute(Market calldata market) internal view returns (V4MarketRoute storage route) {
        route = store.routes[market.collateral][market.debt];
        if (!route.registered) revert MarketNotSupported(market.collateral, market.debt);
    }
}
