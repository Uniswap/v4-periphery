// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {ILockCallback} from "@uniswap/v4-core/contracts/interfaces/callback/ILockCallback.sol";
import {IPoolManager} from "@uniswap/v4-core/contracts/interfaces/IPoolManager.sol";

abstract contract SafeCallback is ILockCallback {
    error NotManager();

    IPoolManager public immutable poolManager;

    constructor(IPoolManager _manager) {
        poolManager = _manager;
    }

    modifier onlyByManager() {
        if (msg.sender != address(poolManager)) revert NotManager();
        _;
    }

    /// @dev There is no way to force the onlyByManager modifier but for this callback to be safe, it MUST check that the msg.sender is the pool manager.
    function lockAcquired(bytes calldata data) external onlyByManager returns (bytes memory) {
        return _lockAcquired(data);
    }

    function _lockAcquired(bytes calldata data) internal virtual returns (bytes memory);
}
