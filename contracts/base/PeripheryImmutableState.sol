// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "../interfaces/IPeripheryImmutableState.sol";

/// @title Immutable state
/// @notice Immutable state used by periphery contracts
abstract contract PeripheryImmutableState is IPeripheryImmutableState {
    /// @inheritdoc IPeripheryImmutableState
    address public immutable override poolManager;
    /// @inheritdoc IPeripheryImmutableState
    address public immutable override WETH9;

    constructor(address _poolManager, address _WETH9) {
        poolManager = _poolManager;
        WETH9 = _WETH9;
    }
}
