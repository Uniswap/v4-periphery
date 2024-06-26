// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {BaseHook} from "../../../contracts/BaseHook.sol";
import {BaseMiddleware} from "../../../contracts/middleware/BaseMiddleware.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";

contract BaseMiddlewareImplementation is BaseMiddleware {
    constructor(IPoolManager _poolManager, address _implementation, BaseMiddleware addressToEtch)
        BaseMiddleware(_poolManager, _implementation)
    {
        Hooks.validateHookPermissions(IHooks(address(addressToEtch)), BaseHook(_implementation).getHookPermissions());
    }
}
