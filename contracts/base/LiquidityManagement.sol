// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {BalanceDelta} from "@uniswap/v4-core/contracts/types/BalanceDelta.sol";
import {ILockCallback} from "@uniswap/v4-core/contracts/interfaces/callback//ILockCallback.sol";
import {IPeripheryPayments} from "../interfaces/IPeripheryPayments.sol";
import {ILiquidityManagement} from "../interfaces/ILiquidityManagement.sol";
import {PeripheryImmutableState} from "./PeripheryImmutableState.sol";

abstract contract LiquidityManagement is ILockCallback, ILiquidityManagement, PeripheryImmutableState {
    function mintEntry(MintParams memory params)
        internal
        returns (uint256 tokenId, uint128 liquidity, BalanceDelta delta)
    {
        // poolManager.lock call here
    }

    function lockAcquired(bytes calldata rawData) external override returns (bytes memory) {
        // TODO: handle mint/add/decrease liquidity here
        return abi.encode(0);
    }
}
