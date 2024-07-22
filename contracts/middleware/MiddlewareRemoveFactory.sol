// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {BaseMiddlewareFactory} from "./BaseMiddlewareFactory.sol";
import {MiddlewareRemoveNoDeltas} from "./MiddlewareRemoveNoDeltas.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

contract MiddlewareRemoveFactory is BaseMiddlewareFactory {
    constructor(IPoolManager _manager) BaseMiddlewareFactory(_manager) {}

    function _deployMiddleware(address implementation, bytes32 salt) internal override returns (address middleware) {
        middleware = address(new MiddlewareRemoveNoDeltas{salt: salt}(manager, implementation));
    }
}
