// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IERC20Minimal} from "@uniswap/v4-core/src/interfaces/external/IERC20Minimal.sol";
import {V4Router} from "../../../src/V4Router.sol";
import {ReentrancyLock} from "../../../src/base/ReentrancyLock.sol";

contract V4RouterImplementation is V4Router, ReentrancyLock {
    constructor(IPoolManager _poolManager) V4Router(_poolManager) {}

    function executeActions(bytes calldata params) external isNotLocked {
        _executeActions(params);
    }

    function _pay(address token, address payer, address recipient, uint256 amount) internal override {
        IERC20Minimal(token).transferFrom(payer, recipient, amount);
    }

    function _msgSender() internal view override returns (address) {
        return _getLocker();
    }
}
