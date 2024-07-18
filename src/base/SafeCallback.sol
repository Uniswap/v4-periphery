// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {ImmutableState} from "./ImmutableState.sol";

abstract contract SafeCallback is ImmutableState, IUnlockCallback {
    error NotManager();

    modifier onlyByManager() {
        if (msg.sender != address(manager)) revert NotManager();
        _;
    }

    /// @dev We force the onlyByManager modifier by exposing a virtual function after the onlyByManager check.
    function unlockCallback(bytes calldata data) external onlyByManager returns (bytes memory) {
        return _unlockCallback(data);
    }

    function _unlockCallback(bytes calldata data) internal virtual returns (bytes memory);
}
