// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {BaseHook} from "../../../contracts/BaseHook.sol";
import {FeeTaking} from "../../../contracts/hooks/examples/FeeTaking.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";

contract FeeTakingImplementation is FeeTaking {
    constructor(
        IPoolManager _poolManager,
        uint128 _swapFeeBips,
        address _owner,
        address _treasury,
        FeeTaking addressToEtch
    ) FeeTaking(_poolManager, _swapFeeBips, _owner, _treasury) {
        Hooks.validateHookPermissions(addressToEtch, getHookPermissions());
    }

    // make this a no-op in testing
    function validateHookAddress(BaseHook _this) internal pure override {}
}
