// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.19;

import {SafeCallback} from "./SafeCallback.sol";
import {IPoolManager} from "@uniswap/v4-core/contracts/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/contracts/types/PoolKey.sol";

abstract contract LockAndBatchCall is SafeCallback {
    error NotSelf();
    error OnlyExternal();
    error CallFail(bytes reason);

    modifier onlyBySelf() {
        if (msg.sender != address(this)) revert NotSelf();
        _;
    }

    modifier onlyByExternalCaller() {
        if (msg.sender == address(this)) revert OnlyExternal();
        _;
    }

    function execute(bytes memory executeData, bytes memory settleData) external {
        (bytes memory lockReturnData) = poolManager.lock(abi.encode(executeData, settleData));
        (bytes memory executeReturnData, bytes memory settleReturnData) = abi.decode(lockReturnData, (bytes, bytes));
        _handleAfterExecute(executeReturnData, settleReturnData);
    }

    /// @param data Data passed from the top-level execute function to the internal (and overrideable) _executeWithLockCalls and _settle function.
    /// @dev lockAcquired is responsible for executing the internal calls under the lock and settling open deltas left on the pool
    function _lockAcquired(bytes calldata data) internal override returns (bytes memory) {
        (bytes memory executeData, bytes memory settleData) = abi.decode(data, (bytes, bytes));
        bytes memory executeReturnData = _executeWithLockCalls(executeData);
        bytes memory settleReturnData = _settle(settleData);
        return abi.encode(executeReturnData, settleReturnData);
    }

    function initializeWithLock(PoolKey memory key, uint160 sqrtPriceX96, bytes calldata hookData)
        external
        onlyBySelf
        returns (bytes memory)
    {
        return abi.encode(poolManager.initialize(key, sqrtPriceX96, hookData));
    }

    function modifyPositionWithLock(
        PoolKey calldata key,
        IPoolManager.ModifyPositionParams calldata params,
        bytes calldata hookData
    ) external onlyBySelf returns (bytes memory) {
        return abi.encode(poolManager.modifyPosition(key, params, hookData));
    }

    function swapWithLock(PoolKey memory key, IPoolManager.SwapParams memory params, bytes calldata hookData)
        external
        onlyBySelf
        returns (bytes memory)
    {
        return abi.encode(poolManager.swap(key, params, hookData));
    }

    function donateWithLock(PoolKey memory key, uint256 amount0, uint256 amount1, bytes calldata hookData)
        external
        onlyBySelf
        returns (bytes memory)
    {
        return abi.encode(poolManager.donate(key, amount0, amount1, hookData));
    }

    function _executeWithLockCalls(bytes memory data) internal returns (bytes memory) {
        bytes[] memory calls = abi.decode(data, (bytes[]));
        bytes[] memory callsReturnData = new bytes[](calls.length);
        for (uint256 i = 0; i < calls.length; i++) {
            (bool success, bytes memory returnData) = address(this).call(calls[i]);
            if (!success) revert(string(returnData));
            callsReturnData[i] = returnData;
        }
        return abi.encode(callsReturnData);
    }

    function _settle(bytes memory data) internal virtual returns (bytes memory settleData);
    function _handleAfterExecute(bytes memory callReturnData, bytes memory settleReturnData) internal virtual;
}
