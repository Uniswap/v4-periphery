// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {BaseHook} from "../../BaseHook.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

contract VolatilityOracle is BaseHook {
    using LPFeeLibrary for uint24;

    error MustUseDynamicFee();

    uint32 immutable deployTimestamp;

    /// @dev For mocking
    function _blockTimestamp() internal view virtual returns (uint32) {
        return uint32(block.timestamp);
    }

    constructor(IPoolManager _manager) BaseHook(_manager) {
        deployTimestamp = _blockTimestamp();
    }

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: true,
            beforeAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterAddLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: false,
            afterSwap: false,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    function beforeInitialize(address, PoolKey calldata key, uint160, bytes calldata)
        external
        pure
        override
        returns (bytes4)
    {
        if (!key.fee.isDynamicFee()) revert MustUseDynamicFee();
        return VolatilityOracle.beforeInitialize.selector;
    }

    function setFee(PoolKey calldata key) public {
        uint24 startingFee = 3000;
        uint32 lapsed = _blockTimestamp() - deployTimestamp;
        uint24 fee = startingFee + (uint24(lapsed) * 100) / 60; // 100 bps a minute
        manager.updateDynamicLPFee(key, fee); // initial fee 0.30%
    }

    function afterInitialize(address, PoolKey calldata key, uint160, int24, bytes calldata)
        external
        override
        returns (bytes4)
    {
        setFee(key);
        return BaseHook.afterInitialize.selector;
    }
}
