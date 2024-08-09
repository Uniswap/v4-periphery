// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {BaseMiddlewareImplementation} from "./BaseMiddlewareImplemenation.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

contract BaseMiddlewareFactoryImplementation {
    event MiddlewareCreated(address implementation, address middleware);

    mapping(address => address) private _implementations;

    IPoolManager public immutable poolManager;

    constructor(IPoolManager _poolManager) {
        poolManager = _poolManager;
    }

    function getImplementation(address middleware) external view returns (address implementation) {
        return _implementations[middleware];
    }

    function createMiddleware(address implementation, bytes32 salt) external returns (address middleware) {
        middleware = _deployMiddleware(implementation, salt);
        _implementations[middleware] = implementation;
        emit MiddlewareCreated(implementation, middleware);
    }

    function _deployMiddleware(address implementation, bytes32 salt) internal returns (address middleware) {
        middleware = address(new BaseMiddlewareImplementation{salt: salt}(poolManager, implementation));
    }
}
