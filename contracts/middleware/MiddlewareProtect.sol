// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BaseMiddleware} from "./BaseMiddleware.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {console} from "../../lib/forge-std/src/console.sol";
import {BaseHook} from "./../BaseHook.sol";

contract MiddlewareProtect is BaseMiddleware {
    bool private swapBlocked;
    bool private removeBlocked;

    uint256 public constant gasLimit = 100000;

    error ActionBetweenHook();

    constructor(IPoolManager _poolManager, address _impl) BaseMiddleware(_poolManager, _impl) {}

    modifier swapNotBlocked() {
        if (swapBlocked) {
            revert ActionBetweenHook();
        }
        _;
    }

    modifier removeNotBlocked() {
        if (removeBlocked) {
            revert ActionBetweenHook();
        }
        _;
    }

    // block swaps and removes
    function beforeSwap(address, PoolKey calldata, IPoolManager.SwapParams calldata, bytes calldata)
        external
        swapNotBlocked
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        swapBlocked = true;
        removeBlocked = true;
        console.log("beforeSwap middleware");
        (bool success, bytes memory returnData) = implementation.delegatecall{gas: gasLimit}(msg.data);
        require(success);
        swapBlocked = false;
        removeBlocked = false;
        return abi.decode(returnData, (bytes4, BeforeSwapDelta, uint24));
    }

    // afterSwap - no protections

    // block swaps
    function beforeAddLiquidity(address, PoolKey calldata, IPoolManager.ModifyLiquidityParams calldata, bytes calldata)
        external
        returns (bytes4)
    {
        swapBlocked = true;
        console.log("beforeAddLiquidity middleware");
        (bool success, bytes memory returnData) = implementation.delegatecall{gas: gasLimit}(msg.data);
        require(success);
        swapBlocked = false;
        return abi.decode(returnData, (bytes4));
    }

    // afterAddLiquidity - no protections

    // block swaps and reverts
    function beforeRemoveLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        bytes calldata
    ) external removeNotBlocked returns (bytes4) {
        swapBlocked = true;
        console.log("beforeRemoveLiquidity middleware");
        implementation.delegatecall{gas: gasLimit}(msg.data);
        swapBlocked = false;
        return BaseHook.beforeRemoveLiquidity.selector;
    }

    // block reverts
    function afterRemoveLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        bytes calldata
    ) external returns (bytes4, BalanceDelta) {
        console.log("afterRemoveLiquidity middleware");
        implementation.delegatecall{gas: gasLimit}(msg.data);
        return (BaseHook.afterRemoveLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }
}
