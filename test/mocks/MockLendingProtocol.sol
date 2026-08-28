// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";

/// @notice Minimal stand-in for a lending protocol singleton: the call target a MarginAccount
///         invokes. Implements the four function signatures MockLendingAdapter encodes, moves a
///         configured collateral and debt token, and records the onBehalf account it was called
///         with so tests can assert the account always passes itself.
contract MockLendingProtocol {
    using SafeERC20 for IERC20;

    IERC20 public immutable collateralToken;
    IERC20 public immutable debtToken;

    mapping(address account => uint256 amount) public collateralOf;
    mapping(address account => uint256 amount) public debtOf;

    // Cumulative token movement per account, measured as this contract's own balance delta rather
    // than the requested amount, so a ledger write that does not match the transfer is observable.
    mapping(address account => uint256 amount) public suppliedOf;
    mapping(address account => uint256 amount) public withdrawnOf;
    mapping(address account => uint256 amount) public borrowedOf;
    mapping(address account => uint256 amount) public repaidOf;

    address public lastAccount;
    address public lastReceiver;

    // When true, withdraw delivers the underlying to the caller (the account) rather than the encoded
    // receiver, modeling Aave v4's Spoke.withdraw which sends to msg.sender. Lets the account test
    // exercise the measure-and-forward path.
    bool public withdrawToCaller;

    constructor(IERC20 collateralToken_, IERC20 debtToken_) {
        collateralToken = collateralToken_;
        debtToken = debtToken_;
    }

    function setDebt(address account, uint256 amount) external {
        debtOf[account] = amount;
    }

    function setWithdrawToCaller(bool value) external {
        withdrawToCaller = value;
    }

    function supplyCollateral(address account, uint256 amount) external {
        lastAccount = account;
        uint256 balanceBefore = collateralToken.balanceOf(address(this));
        collateralToken.safeTransferFrom(msg.sender, address(this), amount);
        suppliedOf[account] += collateralToken.balanceOf(address(this)) - balanceBefore;
        collateralOf[account] += amount;
    }

    function withdrawCollateral(address account, uint256 amount, address receiver) external {
        lastAccount = account;
        lastReceiver = receiver;
        collateralOf[account] -= amount;
        uint256 balanceBefore = collateralToken.balanceOf(address(this));
        collateralToken.safeTransfer(withdrawToCaller ? msg.sender : receiver, amount);
        withdrawnOf[account] += balanceBefore - collateralToken.balanceOf(address(this));
    }

    function borrow(address account, uint256 amount, address receiver) external {
        lastAccount = account;
        lastReceiver = receiver;
        debtOf[account] += amount;
        uint256 balanceBefore = debtToken.balanceOf(address(this));
        debtToken.safeTransfer(receiver, amount);
        borrowedOf[account] += balanceBefore - debtToken.balanceOf(address(this));
    }

    function repay(address account, uint256 amount) external {
        lastAccount = account;
        uint256 owed = debtOf[account];
        uint256 pay = amount == type(uint256).max ? owed : amount;
        uint256 balanceBefore = debtToken.balanceOf(address(this));
        debtToken.safeTransferFrom(msg.sender, address(this), pay);
        repaidOf[account] += debtToken.balanceOf(address(this)) - balanceBefore;
        debtOf[account] = owed - pay;
    }
}
