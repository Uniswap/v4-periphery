// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {BaseHook} from "../../../contracts/BaseHook.sol";
import {FeeTakingLite} from "../../../contracts/hooks/examples/FeeTakingLite.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";

contract FeeTakingLiteImplementation is FeeTakingLite {
    constructor(IPoolManager _poolManager, FeeTakingLite addressToEtch) FeeTakingLite(_poolManager) {
        //Hooks.validateHookPermissions(addressToEtch, getHookPermissions());
    }

    // make this a no-op in testing
    //function validateHookAddress(BaseHook _this) internal pure override {}
}
