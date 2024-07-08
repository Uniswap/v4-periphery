// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {MiddlewareRemove} from "./MiddlewareRemove.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IBaseHook} from "../interfaces/IBaseHook.sol";
import {BaseMiddlewareFactory} from "./BaseMiddlewareFactory.sol";

contract MiddlewareRemoveFactory is BaseMiddlewareFactory {
    constructor(IPoolManager _poolManager) BaseMiddlewareFactory(_poolManager) {}

    function _deployMiddleware(address implementation, bytes32 salt) internal override returns (address middleware) {
        return address(new MiddlewareRemove{salt: salt}(poolManager, IBaseHook(implementation)));
    }
}
