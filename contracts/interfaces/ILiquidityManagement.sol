// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {ILockCallback} from "@uniswap/v4-core/contracts/interfaces/callback//ILockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/contracts/types/PoolKey.sol";

interface ILiquidityManagement is ILockCallback {
    struct MintParams {
        PoolKey poolKey;
        int24 tickLower;
        int24 tickUpper;
        uint256 amount0Desired;
        uint256 amount1Desired;
        uint256 amount0Min;
        uint256 amount1Min;
        address recipient;
        uint256 deadline;
        bytes hookData;
    }
}
