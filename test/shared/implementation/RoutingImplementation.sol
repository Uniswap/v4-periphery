// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {UniswapV4Routing} from "../../../contracts/Routing.sol";
import {IPoolManager} from "@uniswap/v4-core/contracts/interfaces/IPoolManager.sol";
import {IERC20Minimal} from "@uniswap/v4-core/contracts/interfaces/external/IERC20Minimal.sol";

contract RoutingImplementation is UniswapV4Routing {
    constructor(IPoolManager _poolManager) UniswapV4Routing(_poolManager) {}

    function swap(SwapType swapType, bytes memory params) external {
        v4Swap(swapType, params);
    }

    function _pay(address token, address payer, address recipient, uint256 amount) internal override {
        IERC20Minimal(token).transferFrom(payer, recipient, amount);
    }
}
