// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {IMiddlewareFactory} from "../interfaces/IMiddlewareFactory.sol";
import {MiddlewareProtect} from "./MiddlewareProtect.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IBaseHook} from "../interfaces/IBaseHook.sol";

contract MiddlewareProtectFactory is IMiddlewareFactory {
    mapping(address => address) private _implementations;

    IPoolManager public immutable poolManager;

    constructor(IPoolManager _poolManager) {
        poolManager = _poolManager;
    }

    function getImplementation(address middleware) external view override returns (address implementation) {
        return _implementations[middleware];
    }

    function createMiddleware(address implementation, bytes32 salt) external override returns (address middleware) {
        middleware = address(new MiddlewareProtect{salt: salt}(poolManager, IBaseHook(implementation)));
        _implementations[middleware] = implementation;
        emit MiddlewareCreated(implementation, middleware);
    }
}
