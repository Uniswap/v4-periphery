// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BaseMiddleware} from "./BaseMiddleware.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {console} from "../../lib/forge-std/src/console.sol";
import {BaseHook} from "./../BaseHook.sol";
import {ReentrancyState} from "./../libraries/ReentrancyState.sol";

contract MiddlewareProtect is BaseMiddleware {
    uint256 public constant gasLimit = 1000000;

    error ActionBetweenHook();

    constructor(IPoolManager _poolManager, address _impl) BaseMiddleware(_poolManager, _impl) {}

    modifier swapNotLocked() {
        if (ReentrancyState.swapLocked()) {
            revert ActionBetweenHook();
        }
        _;
    }

    modifier removeNotLocked() {
        if (ReentrancyState.removeLocked()) {
            revert ActionBetweenHook();
        }
        _;
    }

    // block swaps and removes
    function beforeSwap(address, PoolKey calldata, IPoolManager.SwapParams calldata, bytes calldata)
        external
        swapNotLocked
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        ReentrancyState.lockSwapRemove();
        console.log("beforeSwap middleware");
        (bool success, bytes memory returnData) = implementation.delegatecall{gas: gasLimit}(msg.data);
        require(success);
        ReentrancyState.unlock();
        return abi.decode(returnData, (bytes4, BeforeSwapDelta, uint24));
    }

    // afterSwap - no protections

    // block swaps
    function beforeAddLiquidity(address, PoolKey calldata, IPoolManager.ModifyLiquidityParams calldata, bytes calldata)
        external
        returns (bytes4)
    {
        ReentrancyState.lockSwap();
        console.log("beforeAddLiquidity middleware");
        (bool success, bytes memory returnData) = implementation.delegatecall{gas: gasLimit}(msg.data);
        require(success);
        ReentrancyState.unlock();
        return abi.decode(returnData, (bytes4));
    }

    // afterAddLiquidity - no protections

    // block swaps and reverts
    function beforeRemoveLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        bytes calldata
    ) external removeNotLocked returns (bytes4) {
        ReentrancyState.lockSwap();
        console.log("beforeRemoveLiquidity middleware");
        implementation.delegatecall{gas: gasLimit}(msg.data);
        ReentrancyState.unlock();
        return BaseHook.beforeRemoveLiquidity.selector;
    }

    // block reverts
    function afterRemoveLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        BalanceDelta,
        bytes calldata
    ) external returns (bytes4, BalanceDelta) {
        console.log("afterRemoveLiquidity middleware");
        implementation.delegatecall{gas: gasLimit}(msg.data);
        return (BaseHook.afterRemoveLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }
}
