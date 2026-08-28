// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IAmountResolver} from "../interfaces/IAmountResolver.sol";
import {Market} from "../types/Market.sol";

/// @title PositionAmountResolver
/// @author Uniswap Labs
/// @notice Implements `IAmountResolver` over the adapter's own `ILendingAdapter.positionOf`, so
///         every lending adapter doubles as a resolver for position-dependent route amounts. A
///         full-close route resolves `DEBT` to buy exactly the live, interest-accrued debt at
///         execution time (no offchain accrual buffer, no over-buy); a full-withdrawal route
///         resolves `COLLATERAL` for a balance that is only known when the transaction executes.
/// @dev    Context ABI: `abi.encode(PositionAmount kind, address account, Market market)`.
///         Semantics inherit from `positionOf`: amounts are the venue's current values (debt
///         interest-accrued; collateral per the venue's own accrual, see
///         `ILendingAdapter.positionOf`), and an unrouted market reverts `MarketNotSupported`
///         exactly as the read surface does. Malformed or out-of-range context reverts in
///         `abi.decode`.
abstract contract PositionAmountResolver is IAmountResolver {
    /// @notice Which side of the `(account, market)` position the resolver returns.
    enum PositionAmount {
        DEBT,
        COLLATERAL
    }

    /// @notice The adapter's position read (`ILendingAdapter.positionOf`). Declared here as a
    ///         public virtual so `resolveAmount` reads it with an internal call instead of an
    ///         external self-call; the implementing adapter overrides both declarations.
    /// @param account The MarginAccount holding the position.
    /// @param market The (collateral, debt) pair identifying the lending market.
    /// @return collateralAmount The venue's current collateral balance (see
    ///         `ILendingAdapter.positionOf` for per-venue accrual semantics).
    /// @return debtAmount The outstanding debt with accrued interest.
    function positionOf(address account, Market memory market)
        public
        view
        virtual
        returns (uint256 collateralAmount, uint256 debtAmount);

    /// @inheritdoc IAmountResolver
    function resolveAmount(bytes calldata context) external view returns (uint256 amount) {
        (PositionAmount kind, address account, Market memory market) =
            abi.decode(context, (PositionAmount, address, Market));
        (uint256 collateralAmount, uint256 debtAmount) = positionOf(account, market);
        return kind == PositionAmount.DEBT ? debtAmount : collateralAmount;
    }
}
