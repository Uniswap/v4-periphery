// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {BaseHook} from "../../../contracts/BaseHook.sol";
import {RemoveMiddleware} from "../../../contracts/hooks/examples/RemoveMiddleware.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";

contract RemoveMiddlewareImplementation is RemoveMiddleware {
    constructor(IPoolManager _poolManager, address _implementation, RemoveMiddleware addressToEtch)
        RemoveMiddleware(_poolManager, _implementation)
    {
        //Hooks.validateHookPermissions(addressToEtch, getHookPermissions());
    }

    // make this a no-op in testing
    //function validateHookAddress(BaseHook _this) internal pure override {}
}
