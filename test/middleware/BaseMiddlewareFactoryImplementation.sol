// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {BaseMiddlewareImplementation} from "./BaseMiddlewareImplemenation.sol";
import {BaseMiddlewareFactory} from "./../../contracts/middleware/BaseMiddlewareFactory.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

contract BaseMiddlewareFactoryImplementation is BaseMiddlewareFactory {
    constructor(IPoolManager _poolManager) BaseMiddlewareFactory(_poolManager) {}

    function _deployMiddleware(address implementation, bytes32 salt) internal override returns (address middleware) {
        middleware = address(new BaseMiddlewareImplementation{salt: salt}(poolManager, implementation));
    }
}
