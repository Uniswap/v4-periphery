// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {Hooks} from "@uniswap/v4-core/contracts/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/contracts/interfaces/IPoolManager.sol";
import {BalanceDelta} from "@uniswap/v4-core/contracts/types/BalanceDelta.sol";
import {PoolKey} from "@uniswap/v4-core/contracts/types/PoolKey.sol";

/// @title UniswapV4Routing
/// @notice Abstract contract that contains all internal logic needed for routing through Uniswap V4 pools
abstract contract UniswapV4Routing {
    IPoolManager immutable poolManager;

    error NotPoolManager();
    error InvalidSwapType();

    struct SwapInfo {
        SwapType swapType;
        bytes params;
    }

    struct ExactInputParams {
        PoolKey[] path; // TODO: pack this and get rid of redundant token (ultimately will NOT be PoolKey)
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
    }

    enum SwapType {
        ExactInput,
        ExactInputSingle,
        ExactOutput,
        ExactOutputSingle
    }

    /// @dev Only the pool manager may call this function
    modifier poolManagerOnly() {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        _;
    }

    modifier checkDeadline(uint256 deadline) {
        require(block.timestamp <= deadline, 'Transaction too old');
        _;
    }

    constructor(IPoolManager _poolManager) {
        poolManager = _poolManager;
    }

    function v4Swap(SwapInfo memory swapInfo, uint256 deadline) internal checkDeadline(deadline) {
        poolManager.lock(abi.encode(swapInfo));
    }

    function lockAcquired(bytes calldata encodedSwapInfo) external poolManagerOnly() returns (bytes memory) {
        SwapInfo memory swapInfo = abi.decode(encodedSwapInfo, (SwapInfo));

        if (swapInfo.swapType == SwapType.ExactInput) {
            _swapExactInput(abi.decode(swapInfo.params, (ExactInputParams)));
        } else {
            revert InvalidSwapType();
        }

        return bytes("");
    }

    function _swapExactInput(ExactInputParams memory params) private {
        for (uint256 i = 0; i < params.path.length; i++) {
          
        }
    }


}
