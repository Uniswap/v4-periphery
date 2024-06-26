// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {BaseHook} from "../../../contracts/BaseHook.sol";
import {FeeTakingLite} from "../../middleware/FeeTakingLite.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";

contract FeeTakingLiteImplementation is FeeTakingLite {
    constructor(IPoolManager _poolManager, FeeTakingLite addressToEtch) FeeTakingLite(_poolManager) {}
}