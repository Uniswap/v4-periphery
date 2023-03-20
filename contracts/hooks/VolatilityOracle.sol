// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.19;

import {IPoolManager} from "@uniswap/core-next/contracts/interfaces/IPoolManager.sol";
import {IDynamicFeeManager} from "@uniswap/core-next/contracts/interfaces/IDynamicFeeManager.sol";
import {Hooks} from '@uniswap/core-next/contracts/libraries/Hooks.sol';
import {BaseHook} from "./BaseHook.sol";

contract VolatilityOracle is BaseHook, IDynamicFeeManager {
    uint32 deployTimestamp;

    function getFee(IPoolManager.PoolKey calldata) external view returns (uint24) {
        uint24 startingFee = 3000;
        uint32 lapsed = _blockTimestamp() - deployTimestamp;
        return startingFee + (uint24(lapsed) * 100) / 60; // 100 bps a minute
    }

    /// @dev For mocking
    function _blockTimestamp() internal view virtual returns (uint32) {
        return uint32(block.timestamp);
    }

    constructor(IPoolManager _poolManager) BaseHook(_poolManager) {
        Hooks.validateHookAddress(
            this,
            Hooks.Calls({
                beforeInitialize: false,
                afterInitialize: false,
                beforeModifyPosition: false,
                afterModifyPosition: false,
                beforeSwap: false,
                afterSwap: false,
                beforeDonate: false,
                afterDonate: false
            })
        );
        deployTimestamp = _blockTimestamp();
    }
}
