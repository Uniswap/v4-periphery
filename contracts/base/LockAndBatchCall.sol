// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.19;

import {SafeCallback} from "./SafeCallback.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {CallsWithLock} from "./CallsWithLock.sol";

abstract contract LockAndBatchCall is CallsWithLock, SafeCallback {
    error CallFail(bytes reason);

    function _settle(address sender, bytes memory data) internal virtual returns (bytes memory settleData);
    function _handleAfterExecute(bytes memory callReturnData, bytes memory settleReturnData) internal virtual;

    /// @param executeData The function selectors and calldata for any of the function selectors in ICallsWithLock encoded as an array of bytes.
    function execute(bytes memory executeData, bytes memory settleData) external {
        (bytes memory lockReturnData) =
            poolManager.unlock(abi.encode(executeData, abi.encode(msg.sender, settleData)));
        (bytes memory executeReturnData, bytes memory settleReturnData) = abi.decode(lockReturnData, (bytes, bytes));
        _handleAfterExecute(executeReturnData, settleReturnData);
    }

    /// @param data This data is passed from the top-level execute function to the internal _executeWithLockCalls and _settle function. It is decoded as two separate dynamic bytes parameters.
    /// @dev _unlockCallback is responsible for executing the internal calls under the lock and settling open deltas left on the pool
    function _unlockCallback(bytes calldata data) internal override returns (bytes memory) {
        (bytes memory executeData, bytes memory settleDataWithSender) = abi.decode(data, (bytes, bytes));
        (address sender, bytes memory settleData) = abi.decode(settleDataWithSender, (address, bytes));
        return abi.encode(_executeWithLockCalls(executeData), _settle(sender, settleData));
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
}
