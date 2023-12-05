// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {ILockCallback} from "@uniswap/v4-core/contracts/interfaces/callback/ILockCallback.sol";
import {IPoolManager} from "@uniswap/v4-core/contracts/interfaces/IPoolManager.sol";

abstract contract SafeCallback is ILockCallback {
    error NotManager();

    function manager() public view virtual returns (IPoolManager);

    modifier onlyByManager() {
        if (msg.sender != address(manager())) revert NotManager();
        _;
    }

    /// @dev There is no way to force the onlyByManager modifier but for this callback to be safe, it MUST check that the msg.sender is the pool manager.
    function lockAcquired(bytes calldata data) external virtual returns (bytes memory);
}
