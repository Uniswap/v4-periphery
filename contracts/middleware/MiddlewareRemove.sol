// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BaseMiddleware} from "./BaseMiddleware.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BaseHook} from "./../BaseHook.sol";
import {IBaseHook} from "./../interfaces/IBaseHook.sol";
import {console} from "../../lib/forge-std/src/console.sol";

contract MiddlewareRemove is BaseMiddleware {
    uint256 public constant gasLimit = 1000000;

    constructor(IPoolManager _poolManager, IBaseHook _implementation) BaseMiddleware(_poolManager, _implementation) {}

    function beforeRemoveLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        bytes calldata
    ) external override returns (bytes4) {
        console.log("beforeRemoveLiquidity middleware");
        (bool success, bytes memory returnData) = address(implementation).call{gas: gasLimit}(msg.data);
        console.log(success);
        return BaseHook.beforeRemoveLiquidity.selector;
    }

    function afterRemoveLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        BalanceDelta,
        bytes calldata
    ) external override returns (bytes4, BalanceDelta) {
        console.log("afterRemoveLiquidity middleware");
        (bool success, bytes memory returnData) = address(implementation).call{gas: gasLimit}(msg.data);
        console.log(success);
        // hook cannot return delta
        return (BaseHook.afterRemoveLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }
}
