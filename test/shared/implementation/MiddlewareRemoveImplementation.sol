// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {BaseHook} from "../../../contracts/BaseHook.sol";
import {MiddlewareRemove} from "../../../contracts/middleware/MiddlewareRemove.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";

contract MiddlewareRemoveImplementation is MiddlewareRemove {
    constructor(IPoolManager _poolManager, address _implementation, MiddlewareRemove addressToEtch)
        MiddlewareRemove(_poolManager, _implementation)
    {
        //Hooks.validateHookPermissions(addressToEtch, getHookPermissions());
    }

    // make this a no-op in testing
    //function validateHookAddress(BaseHook _this) internal pure override {}
}
