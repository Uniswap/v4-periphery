// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {BaseHook} from "../../../contracts/BaseHook.sol";
import {GeomeanOracle} from "../../../contracts/hooks/examples/GeomeanOracle.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";

contract GeomeanOracleImplementation is GeomeanOracle {
    uint32 public time;

    constructor(IPoolManager _poolManager, GeomeanOracle addressToEtch) GeomeanOracle(_poolManager) {
        Hooks.validateHookPermissions(addressToEtch, getHookPermissions());
    }

    // make this a no-op in testing
    function validateHookAddress(BaseHook _this) internal pure override {}

    function setTime(uint32 _time) external {
        time = _time;
    }

    function _blockTimestamp() internal view override returns (uint32) {
        return time;
    }
}
