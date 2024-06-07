// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {BaseHook} from "../../../contracts/BaseHook.sol";
import {TakingFee} from "../../../contracts/hooks/examples/TakingFee.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";

contract TakingFeeImplementation is TakingFee {
    constructor(IPoolManager _poolManager, uint128 _swapFeeBips, TakingFee addressToEtch)
        TakingFee(_poolManager, _swapFeeBips)
    {
        Hooks.validateHookPermissions(addressToEtch, getHookPermissions());
    }

    // make this a no-op in testing
    function validateHookAddress(BaseHook _this) internal pure override {}
}
