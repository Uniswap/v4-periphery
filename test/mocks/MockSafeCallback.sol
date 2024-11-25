// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

import "../../src/base/SafeCallback.sol";

contract MockSafeCallback is SafeCallback {
    constructor(IPoolManager _poolManager) SafeCallback(_poolManager) {}

    function unlockManager(uint256 num) external returns (bytes memory) {
        return poolManager.unlock(abi.encode(num));
    }

    function _unlockCallback(bytes calldata data) internal pure override returns (bytes memory) {
        return data;
    }
}
