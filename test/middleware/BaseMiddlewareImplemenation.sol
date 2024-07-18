// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {BaseMiddleware} from "./../../contracts/middleware/BaseMiddleware.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

contract BaseMiddlewareImplementation is BaseMiddleware {
    constructor(IPoolManager _manager, address _impl) BaseMiddleware(_manager, _impl) {}
}
