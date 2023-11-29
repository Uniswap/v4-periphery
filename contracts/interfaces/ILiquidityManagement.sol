// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {ILockCallback} from "@uniswap/v4-core/contracts/interfaces/callback//ILockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/contracts/types/PoolKey.sol";

/// @title Liquidity management interface
/// @notice Wrapper around pool manager callbacks
interface ILiquidityManagement is ILockCallback {}
