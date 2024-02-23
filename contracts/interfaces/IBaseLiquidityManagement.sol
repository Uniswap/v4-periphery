// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {PoolKey} from "@uniswap/v4-core/contracts/types/PoolKey.sol";
import {BalanceDelta} from "@uniswap/v4-core/contracts/types/BalanceDelta.sol";

import {IPoolManager} from "@uniswap/v4-core/contracts/interfaces/IPoolManager.sol";
import {ILockCallback} from "@uniswap/v4-core/contracts/interfaces/callback/ILockCallback.sol";
import {LiquidityPosition, LiquidityPositionId} from "../types/LiquidityPositionId.sol";

interface IBaseLiquidityManagement is ILockCallback {
    function liquidityOf(address owner, LiquidityPositionId positionId) external view returns (uint256 liquidity);

    // NOTE: handles add/remove/collect
    function modifyLiquidity(
        PoolKey memory key,
        IPoolManager.ModifyPositionParams memory params,
        bytes calldata hookData,
        address owner
    ) external payable returns (BalanceDelta delta);
}
