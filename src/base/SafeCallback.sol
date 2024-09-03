// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.0;

import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {ImmutableState} from "./ImmutableState.sol";

abstract contract SafeCallback is ImmutableState, IUnlockCallback {
    error NotPoolManager();

    constructor(IPoolManager _poolManager) ImmutableState(_poolManager) {}

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        _;
    }

    /// @dev We force the onlyPoolManager modifier by exposing a virtual function after the onlyPoolManager check.
    function unlockCallback(bytes calldata data) external onlyPoolManager returns (bytes memory) {
        return _unlockCallback(data);
    }

    function _unlockCallback(bytes calldata data) internal virtual returns (bytes memory);
}
