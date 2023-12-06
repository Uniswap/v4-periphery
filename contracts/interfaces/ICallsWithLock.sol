// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {PoolKey} from "@uniswap/v4-core/contracts/types/PoolKey.sol";
import {IPoolManager} from "@uniswap/v4-core/contracts/interfaces/IPoolManager.sol";

interface ICallsWithLock {
    function initializeWithLock(PoolKey memory key, uint160 sqrtPriceX96, bytes calldata hookData)
        external
        returns (bytes memory);

    function modifyPositionWithLock(
        PoolKey calldata key,
        IPoolManager.ModifyPositionParams calldata params,
        bytes calldata hookData
    ) external returns (bytes memory);

    function swapWithLock(PoolKey memory key, IPoolManager.SwapParams memory params, bytes calldata hookData)
        external
        returns (bytes memory);

    function donateWithLock(PoolKey memory key, uint256 amount0, uint256 amount1, bytes calldata hookData)
        external
        returns (bytes memory);
}
