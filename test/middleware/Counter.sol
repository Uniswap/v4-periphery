// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {BaseHook} from "./../../contracts/BaseHook.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";

contract Counter is BaseHook {
    using PoolIdLibrary for PoolKey;

    mapping(PoolId => uint256) public beforeInitializeCount;
    mapping(PoolId => uint256) public afterInitializeCount;

    mapping(PoolId => uint256) public beforeSwapCount;
    mapping(PoolId => uint256) public afterSwapCount;

    mapping(PoolId => uint256) public beforeAddLiquidityCount;
    mapping(PoolId => uint256) public afterAddLiquidityCount;
    mapping(PoolId => uint256) public beforeRemoveLiquidityCount;
    mapping(PoolId => uint256) public afterRemoveLiquidityCount;

    mapping(PoolId => uint256) public beforeDonateCount;
    mapping(PoolId => uint256) public afterDonateCount;

    bytes public lastHookData;

    constructor(IPoolManager _manager) BaseHook(_manager) {}

    // for testing
    function validateHookAddress(BaseHook _this) internal pure override {}

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: true,
            beforeAddLiquidity: true,
            afterAddLiquidity: true,
            beforeRemoveLiquidity: true,
            afterRemoveLiquidity: true,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: true,
            afterDonate: true,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    function beforeInitialize(address, PoolKey calldata key, uint160, bytes calldata hookData)
        external
        override
        onlyByManager
        returns (bytes4)
    {
        beforeInitializeCount[key.toId()]++;
        lastHookData = hookData;
        return BaseHook.beforeInitialize.selector;
    }

    function afterInitialize(address, PoolKey calldata key, uint160, int24, bytes calldata hookData)
        external
        override
        onlyByManager
        returns (bytes4)
    {
        afterInitializeCount[key.toId()]++;
        lastHookData = hookData;
        return BaseHook.afterInitialize.selector;
    }

    function beforeAddLiquidity(
        address,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata,
        bytes calldata hookData
    ) external override onlyByManager returns (bytes4) {
        beforeAddLiquidityCount[key.toId()]++;
        lastHookData = hookData;
        return BaseHook.beforeAddLiquidity.selector;
    }

    function afterAddLiquidity(
        address,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata,
        BalanceDelta,
        bytes calldata hookData
    ) external override onlyByManager returns (bytes4, BalanceDelta) {
        afterAddLiquidityCount[key.toId()]++;
        lastHookData = hookData;
        return (BaseHook.afterAddLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }

    function beforeRemoveLiquidity(
        address,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata,
        bytes calldata hookData
    ) external override onlyByManager returns (bytes4) {
        beforeRemoveLiquidityCount[key.toId()]++;
        lastHookData = hookData;
        return BaseHook.beforeRemoveLiquidity.selector;
    }

    function afterRemoveLiquidity(
        address,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata,
        BalanceDelta,
        bytes calldata hookData
    ) external override onlyByManager returns (bytes4, BalanceDelta) {
        afterRemoveLiquidityCount[key.toId()]++;
        lastHookData = hookData;
        return (BaseHook.afterRemoveLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }

    function beforeSwap(address, PoolKey calldata key, IPoolManager.SwapParams calldata, bytes calldata hookData)
        external
        override
        onlyByManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        beforeSwapCount[key.toId()]++;
        lastHookData = hookData;
        return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    function afterSwap(
        address,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata,
        BalanceDelta,
        bytes calldata hookData
    ) external override onlyByManager returns (bytes4, int128) {
        afterSwapCount[key.toId()]++;
        lastHookData = hookData;
        return (BaseHook.afterSwap.selector, 0);
    }

    function beforeDonate(address, PoolKey calldata key, uint256, uint256, bytes calldata hookData)
        external
        override
        onlyByManager
        returns (bytes4)
    {
        beforeDonateCount[key.toId()]++;
        lastHookData = hookData;
        return BaseHook.beforeDonate.selector;
    }

    function afterDonate(address, PoolKey calldata key, uint256, uint256, bytes calldata hookData)
        external
        override
        onlyByManager
        returns (bytes4)
    {
        afterDonateCount[key.toId()]++;
        lastHookData = hookData;
        return BaseHook.afterDonate.selector;
    }
}
