// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ILendingAdapter} from "../../src/interfaces/ILendingAdapter.sol";
import {Call} from "../../src/types/Call.sol";
import {Market} from "../../src/types/Market.sol";
import {Ltv, toLtv} from "../../src/types/Ltv.sol";
import {PositionData} from "../../src/types/PositionData.sol";
import {MockLendingProtocol} from "./MockLendingProtocol.sol";

/// @notice Minimal configurable test double for `ILendingAdapter`. Encodes calls against a
///         configurable `lendingProtocol` target and lets tests set positions and LTVs. Later
///         milestones extend or specialize as their tests require.
contract MockLendingAdapter is ILendingAdapter {
    address public lendingProtocol;
    Ltv internal _maxLtv = toLtv(0.86e18);

    // markets flagged routable by tests, keyed by the hash of the full market key (pair plus data)
    mapping(bytes32 marketHash => bool supported) internal _supported;

    // when set, describePosition reverts, simulating a venue oracle read that fails (e.g. downtime)
    bool public describeReverts;

    // when set, encodeRepay returns no calls, modeling a debt-free repay the account must skip
    bool public repayNoOp;

    constructor(address lendingProtocol_) {
        lendingProtocol = lendingProtocol_;
    }

    function setDescribeReverts(bool v) external {
        describeReverts = v;
    }

    function setRepayNoOp(bool v) external {
        repayNoOp = v;
    }

    // --- test configuration ---

    function setSupported(Market calldata m, bool supported) external {
        _supported[keccak256(abi.encode(m))] = supported;
    }

    function setMaxLtv(Ltv v) external {
        _maxLtv = v;
    }

    // --- ILendingAdapter ---

    function isSupportedMarket(Market calldata m) external view returns (bool) {
        return _supported[keccak256(abi.encode(m))];
    }

    /// @dev The mock protocol treats supplied collateral as collateral automatically (like Morpho and
    ///      Compound), so the supply is the whole sequence.
    function encodeSupplyCollateral(address account, Market calldata, uint256 amount)
        external
        pure
        returns (Call[] memory calls)
    {
        calls = new Call[](1);
        calls[0] = Call({value: 0, data: abi.encodeWithSignature("supplyCollateral(address,uint256)", account, amount)});
    }

    function encodeWithdrawCollateral(address account, Market calldata, uint256 amount, address receiver)
        external
        pure
        returns (Call[] memory calls)
    {
        calls = new Call[](1);
        calls[0] = Call({
            value: 0,
            data: abi.encodeWithSignature("withdrawCollateral(address,uint256,address)", account, amount, receiver)
        });
    }

    function encodeBorrow(address account, Market calldata, uint256 amount)
        external
        pure
        returns (Call[] memory calls)
    {
        // borrow to the account; the account forwards to the validated receiver
        calls = new Call[](1);
        calls[0] = Call({
            value: 0, data: abi.encodeWithSignature("borrow(address,uint256,address)", account, amount, account)
        });
    }

    function encodeRepay(address account, Market calldata, uint256 amount) external view returns (Call[] memory calls) {
        // model an adapter that encodes a no-op for a debt-free position (no calls, which the account skips)
        if (repayNoOp) return new Call[](0);
        calls = new Call[](1);
        calls[0] = Call({value: 0, data: abi.encodeWithSignature("repay(address,uint256)", account, amount)});
    }

    function positionOf(address account, Market calldata)
        external
        view
        returns (uint256 collateralAmount, uint256 debtAmount)
    {
        // reflect the live state of the mock lending protocol so close/withdraw flows read real debt
        MockLendingProtocol p = MockLendingProtocol(lendingProtocol);
        return (p.collateralOf(account), p.debtOf(account));
    }

    function maxLtvWad(Market calldata) external view returns (Ltv) {
        return _maxLtv;
    }

    /// @dev Derived from the live protocol ledger rather than the configurable `maxLtv` stub, so
    ///      `ASSERT_HEALTH` is a real guard instead of a constant that can never bind.
    function currentLtvWad(address account, Market calldata) external view returns (Ltv) {
        MockLendingProtocol p = MockLendingProtocol(lendingProtocol);
        return _ledgerLtv(p.collateralOf(account), p.debtOf(account));
    }

    function describePosition(address account, Market calldata) external view returns (PositionData memory data) {
        if (describeReverts) revert("oracle down");
        MockLendingProtocol p = MockLendingProtocol(lendingProtocol);
        uint256 collateral = p.collateralOf(account);
        uint256 debt = p.debtOf(account);
        Ltv currentLtv = _ledgerLtv(collateral, debt);
        data = PositionData({
            collateralAmount: collateral,
            debtAmount: debt,
            maxLtv: _maxLtv,
            currentLtv: currentLtv,
            healthFactorWad: _healthFactor(currentLtv)
        });
    }

    /// @dev Zero debt is LTV 0; debt with no collateral is unbounded LTV; otherwise `debt/collateral`.
    function _ledgerLtv(uint256 collateral, uint256 debt) internal pure returns (Ltv) {
        if (debt == 0) return toLtv(0);
        if (collateral == 0) return toLtv(type(uint256).max);
        return toLtv(debt * 1e18 / collateral);
    }

    /// @dev The `ILendingAdapter` obligation: `maxLtv / currentLtv` in WAD, max when there is no debt.
    function _healthFactor(Ltv currentLtv) internal view returns (uint256) {
        uint256 current = Ltv.unwrap(currentLtv);
        if (current == 0) return type(uint256).max;
        return Ltv.unwrap(_maxLtv) * 1e18 / current;
    }
}
