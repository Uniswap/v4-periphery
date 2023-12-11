// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {IPoolManager} from "@uniswap/v4-core/contracts/interfaces/IPoolManager.sol";
import {IERC20Minimal} from "@uniswap/v4-core/contracts/interfaces/external/IERC20Minimal.sol";
import {IV4Router} from "../../../contracts/interfaces/IV4Router.sol";
import {V4Router} from "../../../contracts/V4Router.sol";

contract V4RouterImplementation is V4Router {
    constructor(IPoolManager _poolManager) V4Router(_poolManager) {}

    function swap(IV4Router.SwapType swapType, bytes memory params) external {
        _v4Swap(swapType, params);
    }

    function _pay(address token, address payer, address recipient, uint256 amount) internal override {
        IERC20Minimal(token).transferFrom(payer, recipient, amount);
    }
}
