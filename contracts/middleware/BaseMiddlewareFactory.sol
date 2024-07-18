// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {IMiddlewareFactory} from "../interfaces/IMiddlewareFactory.sol";
import {BaseMiddleware} from "./BaseMiddleware.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

abstract contract BaseMiddlewareFactory is IMiddlewareFactory {
    mapping(address => address) private _implementations;

    IPoolManager public immutable manager;

    constructor(IPoolManager _manager) {
        manager = _manager;
    }

    function getImplementation(address middleware) external view override returns (address implementation) {
        return _implementations[middleware];
    }

    function createMiddleware(address implementation, bytes32 salt) external override returns (address middleware) {
        middleware = _deployMiddleware(implementation, salt);
        _implementations[middleware] = implementation;
        emit MiddlewareCreated(implementation, middleware);
    }

    function _deployMiddleware(address implementation, bytes32 salt) internal virtual returns (address middleware) {}
}
