// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {PoolKey} from "@uniswap/v4-core/contracts/types/PoolKey.sol";
import {BalanceDelta} from "@uniswap/v4-core/contracts/types/BalanceDelta.sol";
import {ILockCallback} from "@uniswap/v4-core/contracts/interfaces/callback//ILockCallback.sol";
import {IPeripheryPayments} from "../interfaces/IPeripheryPayments.sol";
import {ILiquidityManagement} from "../interfaces/ILiquidityManagement.sol";
import {PeripheryImmutableState} from "./PeripheryImmutableState.sol";

abstract contract LiquidityManagement is ILockCallback, ILiquidityManagement, PeripheryImmutableState {
    struct AddLiquidityParams {
        PoolKey poolKey;
        int24 tickLower;
        int24 tickUpper;
        uint256 amount0Desired;
        uint256 amount1Desired;
        uint256 amount0Min;
        uint256 amount1Min;
        bytes hookData;
    }

    function mintEntry(MintParams memory params)
        internal
        returns (uint256 tokenId, uint128 liquidity, BalanceDelta delta)
    {
        // TODO: poolManager.lock call here
    }

    /// @notice Add liquidity to an initialized pool
    function addLiquidity(AddLiquidityParams memory params) internal returns (uint128 liquidity, BalanceDelta delta) {
        // TODO: copy over addLiquidity helper here
    }

    function lockAcquired(bytes calldata rawData) external override returns (bytes memory) {
        // TODO: handle mint/add/decrease liquidity here
        return abi.encode(0);
    }
}
