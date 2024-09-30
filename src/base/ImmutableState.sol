// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

/// @title Immutable State
/// @notice A collection of immutable state variables, commonly used across multiple contracts
contract ImmutableState {
    /// @notice The Uniswap v4 PoolManager contract
    IPoolManager public immutable poolManager;

    constructor(IPoolManager _poolManager) {
        poolManager = _poolManager;
    }
}
