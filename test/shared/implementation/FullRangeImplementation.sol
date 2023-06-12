// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {BaseHook} from "../../../contracts/BaseHook.sol";
import {FullRange} from "../../../contracts/hooks/FullRange.sol";
import {IPoolManager} from "@uniswap/core-next/contracts/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/core-next/contracts/libraries/Hooks.sol";

contract FullRangeImplementation is FullRange {
    constructor(IPoolManager _poolManager, FullRange addressToEtch) FullRange(_poolManager) {
        Hooks.validateHookAddress(addressToEtch, getHooksCalls());
    }

    // make this a no-op in testing
    function validateHookAddress(BaseHook _this) internal pure override {}
}
