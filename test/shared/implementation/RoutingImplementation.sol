// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {Routing} from "../../../contracts/Routing.sol";
import {IPoolManager} from "@uniswap/v4-core/contracts/interfaces/IPoolManager.sol";
import {IERC20Minimal} from "@uniswap/v4-core/contracts/interfaces/external/IERC20Minimal.sol";

contract RoutingImplementation is Routing {
    constructor(IPoolManager _poolManager) Routing(_poolManager) {}

    function swap(SwapType swapType, bytes memory params) external {
        v4Swap(swapType, params);
    }

    function _pay(address token, address payer, address recipient, uint256 amount) internal override {
        IERC20Minimal(token).transferFrom(payer, recipient, amount);
    }
}
