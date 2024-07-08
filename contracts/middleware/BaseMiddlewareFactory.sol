// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {IMiddlewareFactory} from "../interfaces/IMiddlewareFactory.sol";
import {BaseMiddleware} from "./BaseMiddleware.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IBaseHook} from "../interfaces/IBaseHook.sol";
import {IBaseImplementation} from "../interfaces/IBaseImplementation.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";

contract BaseMiddlewareFactory is IMiddlewareFactory {
    error AlreadyInitialized();

    mapping(address => address) private _implementations;
    mapping(address => bool) private _initialized;

    IPoolManager public immutable poolManager;

    constructor(IPoolManager _poolManager) {
        poolManager = _poolManager;
    }

    function getImplementation(address middleware) external view override returns (address implementation) {
        return _implementations[middleware];
    }

    function createMiddleware(address implementation, bytes32 salt) external override returns (address middleware) {
        if (_initialized[implementation]) revert AlreadyInitialized();
        _initialized[implementation] = true;
        middleware = _deployMiddleware(implementation, salt);
        Hooks.validateHookPermissions(IHooks(middleware), IBaseImplementation(implementation).getHookPermissions());
        IBaseImplementation(implementation).initializeMiddleware(middleware);
        _implementations[middleware] = implementation;
        emit MiddlewareCreated(implementation, middleware);
    }

    function _deployMiddleware(address implementation, bytes32 salt) internal virtual returns (address middleware) {
        return address(new BaseMiddleware{salt: salt}(poolManager, IBaseHook(implementation)));
    }
}
