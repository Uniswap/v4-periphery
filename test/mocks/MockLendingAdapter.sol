// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ILendingAdapter} from "../../src/interfaces/ILendingAdapter.sol";
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

    mapping(bytes32 pairKey => bool supported) internal _supported;

    // when set non-zero, encode* returns this instead of lendingProtocol (to exercise the
    // account's target == lendingProtocol() check)
    address public forcedTarget;

    constructor(address lendingProtocol_) {
        lendingProtocol = lendingProtocol_;
    }

    function setForcedTarget(address t) external {
        forcedTarget = t;
    }

    function _callTarget() internal view returns (address) {
        return forcedTarget == address(0) ? lendingProtocol : forcedTarget;
    }

    function _pairKey(Market calldata m) internal pure returns (bytes32) {
        return keccak256(abi.encode(m.collateral, m.debt));
    }

    // --- test configuration ---

    function setSupported(Market calldata m, bool supported) external {
        _supported[_pairKey(m)] = supported;
    }

    function setMaxLtv(Ltv v) external {
        _maxLtv = v;
    }

    // --- ILendingAdapter ---

    function isSupportedMarket(Market calldata m) external view returns (bool) {
        return _supported[_pairKey(m)];
    }

    function encodeSupplyCollateral(address account, Market calldata, uint256 amount)
        external
        view
        returns (address, uint256, bytes memory)
    {
        return (_callTarget(), 0, abi.encodeWithSignature("supplyCollateral(address,uint256)", account, amount));
    }

    function encodeWithdrawCollateral(address account, Market calldata, uint256 amount, address receiver)
        external
        view
        returns (address, uint256, bytes memory)
    {
        return (
            _callTarget(),
            0,
            abi.encodeWithSignature("withdrawCollateral(address,uint256,address)", account, amount, receiver)
        );
    }

    function encodeBorrow(address account, Market calldata, uint256 amount)
        external
        view
        returns (address, uint256, bytes memory)
    {
        // borrow to the account; the account forwards to the validated receiver
        return (_callTarget(), 0, abi.encodeWithSignature("borrow(address,uint256,address)", account, amount, account));
    }

    function encodeRepay(address account, Market calldata, uint256 amount)
        external
        view
        returns (address, uint256, bytes memory)
    {
        return (_callTarget(), 0, abi.encodeWithSignature("repay(address,uint256)", account, amount));
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

    function currentLtvWad(address, Market calldata) external view returns (Ltv) {
        return _maxLtv;
    }

    function describePosition(address account, Market calldata) external view returns (PositionData memory data) {
        MockLendingProtocol p = MockLendingProtocol(lendingProtocol);
        uint256 debt = p.debtOf(account);
        data = PositionData({
            collateralAmount: p.collateralOf(account),
            debtAmount: debt,
            maxLtv: _maxLtv,
            currentLtv: debt == 0 ? toLtv(0) : _maxLtv,
            // the mock reports currentLtv == maxLtv, so health factor is 1e18 while debt exists
            healthFactorWad: debt == 0 ? type(uint256).max : 1e18
        });
    }
}
