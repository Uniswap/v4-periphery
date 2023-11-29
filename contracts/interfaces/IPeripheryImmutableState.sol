// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {IPoolManager} from "@uniswap/v4-core/contracts/interfaces/IPoolManager.sol";

/// @title Immutable state
/// @notice Functions that return immutable state
interface IPeripheryImmutableState {
    /// @return Returns the pool manager
    function poolManager() external view returns (IPoolManager);
}
