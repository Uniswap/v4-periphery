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

    address public lastAccount;
    address public lastReceiver;

    constructor(IERC20 collateralToken_, IERC20 debtToken_) {
        collateralToken = collateralToken_;
        debtToken = debtToken_;
    }

    function setDebt(address account, uint256 amount) external {
        debtOf[account] = amount;
    }

    function supplyCollateral(address account, uint256 amount) external {
        lastAccount = account;
        collateralToken.safeTransferFrom(msg.sender, address(this), amount);
        collateralOf[account] += amount;
    }

    function withdrawCollateral(address account, uint256 amount, address receiver) external {
        lastAccount = account;
        lastReceiver = receiver;
        collateralOf[account] -= amount;
        collateralToken.safeTransfer(receiver, amount);
    }

    function borrow(address account, uint256 amount, address receiver) external {
        lastAccount = account;
        lastReceiver = receiver;
        debtOf[account] += amount;
        debtToken.safeTransfer(receiver, amount);
    }

    function repay(address account, uint256 amount) external {
        lastAccount = account;
        uint256 owed = debtOf[account];
        uint256 pay = amount == type(uint256).max ? owed : amount;
        debtToken.safeTransferFrom(msg.sender, address(this), pay);
        debtOf[account] = owed - pay;
    }
}
