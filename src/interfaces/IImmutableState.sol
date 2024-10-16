// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

/// @title Interface for ImmutableState
interface IImmutableState {
    /// @notice The Uniswap v4 PoolManager contract
    function poolManager() external view returns (IPoolManager);
}
