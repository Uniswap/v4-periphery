// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {BaseHook} from "../../../contracts/BaseHook.sol";
import {TWAMMHook} from "../../../contracts/hooks/TWAMMHook.sol";
import {IPoolManager} from "@uniswap/core-next/contracts/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/core-next/contracts/libraries/Hooks.sol";

contract TWAMMImplementation is TWAMMHook {
    constructor(IPoolManager poolManager, uint256 interval, TWAMMHook addressToEtch) TWAMMHook(poolManager, interval) {
        Hooks.validateHookAddress(addressToEtch, getHooksCalls());
    }

    // make this a no-op in testing
    function validateHookAddress(BaseHook _this) internal pure override {}
}
