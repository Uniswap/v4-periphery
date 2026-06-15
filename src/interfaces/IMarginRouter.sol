// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

import {ILendingAdapter} from "./ILendingAdapter.sol";
import {Market} from "../types/Market.sol";
import {Direction} from "../types/Direction.sol";
import {Ltv} from "../types/Ltv.sol";

/// @notice Entry points for opening, closing, and topping up leveraged spot positions. Each call
///         operates on the caller's own MarginAccount, derived from the authenticated caller and a
///         subId, never from a caller-supplied account address. Leverage is built as a single
///         flash-style swap inside one PoolManager unlock: borrow the debt, swap it into collateral,
///         supply the collateral, and draw the debt to settle the swap.
interface IMarginRouter {
    /// @notice Thrown when the deadline has passed.
    error DeadlinePassed(uint256 deadline);
    /// @notice Thrown when a required slippage bound is zero.
    error SlippageBoundRequired();
    /// @notice Thrown when a position would be left or made unhealthy by an operation.
    error PositionUnhealthy();
    /// @notice Thrown when a flow is called with a lending adapter that governance has not allowed.
    error AdapterNotAllowed(address adapter);

    /// @notice Parameters for opening a leveraged position.
    /// @dev The swap always sells the market's debt to buy its collateral; `direction` records
    ///      whether the exposure asset is the collateral (Long) or the debt (Short). Equity is
    ///      provided in the collateral currency.
    struct OpenParams {
        ILendingAdapter adapter;
        Market market;
        Direction direction;
        PoolKey poolKey;
        uint256 equity;
        uint128 collateralToBuy;
        uint128 maxDebtIn;
        uint256 minHopPriceX36;
        uint256 subId;
        uint256 deadline;
    }

    /// @notice Parameters for fully closing a position.
    /// @dev The swap sells collateral to buy exactly the current debt, which is repaid; the
    ///      remaining collateral (realized PnL) is returned to the caller.
    struct CloseParams {
        ILendingAdapter adapter;
        Market market;
        PoolKey poolKey;
        uint128 maxCollateralIn;
        uint256 minHopPriceX36;
        uint256 subId;
        uint256 deadline;
    }

    /// @notice Parameters for partially reducing (delevering) a position.
    /// @dev Sells collateral to buy and repay `debtToRepay` of debt; the position stays open and
    ///      shrinks by the swap's collateral cost and the repaid debt. `maxLtvAfter` asserts the
    ///      resulting LTV (zero to skip the check).
    struct DecreaseParams {
        ILendingAdapter adapter;
        Market market;
        PoolKey poolKey;
        uint256 debtToRepay;
        uint128 maxCollateralIn;
        uint256 minHopPriceX36;
        Ltv maxLtvAfter;
        uint256 subId;
        uint256 deadline;
    }

    /// @notice Parameters for adding collateral to an existing position.
    struct AddCollateralParams {
        ILendingAdapter adapter;
        Market market;
        uint256 amount;
        uint256 subId;
        uint256 deadline;
    }

    /// @notice Opens a leveraged position for the caller, deploying their account if needed.
    /// @dev v1 handles ERC20 collateral pulled via Permit2. Native-ETH equity (wrapping to WETH) is
    ///      a follow-up; callers wrap to WETH themselves for now.
    /// @return account The caller's MarginAccount holding the position.
    function openPosition(OpenParams calldata params) external returns (address account);

    /// @notice Adds leverage to the caller's existing position. Mechanically identical to opening:
    ///         borrow more debt, swap it into collateral, and supply it. Optional added equity is
    ///         pulled via Permit2 (set equity to zero for a pure leverage increase).
    /// @return account The caller's MarginAccount.
    function increasePosition(OpenParams calldata params) external returns (address account);

    /// @notice Fully closes the caller's position, returning collateral (realized PnL) to the caller.
    /// @return account The caller's MarginAccount.
    function closePosition(CloseParams calldata params) external returns (address account);

    /// @notice Partially reduces the caller's position by repaying `debtToRepay`, funded by selling
    ///         collateral. The position stays open.
    /// @return account The caller's MarginAccount.
    function decreasePosition(DecreaseParams calldata params) external returns (address account);

    /// @notice Adds collateral to the caller's position, deploying their account if needed.
    /// @return account The caller's MarginAccount.
    function addCollateral(AddCollateralParams calldata params) external returns (address account);

    /// @notice The deterministic account address for an owner and subId.
    function accountOf(address owner, uint256 subId) external view returns (address);
}
