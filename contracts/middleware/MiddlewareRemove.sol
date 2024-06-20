// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {Proxy} from "@openzeppelin/contracts/proxy/Proxy.sol";
import {BaseMiddleware} from "./BaseMiddleware.sol";
import {BaseHook} from "../BaseHook.sol";
import {console} from "../../lib/forge-std/src/console.sol";
import {BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";

contract MiddlewareRemove is BaseMiddleware {
    bytes internal constant ZERO_BYTES = bytes("");
    uint256 public constant gasLimit = 100000;

    constructor(IPoolManager _poolManager, address _impl) BaseMiddleware(_poolManager, _impl) {}

    function beforeRemoveLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        bytes calldata
    ) external returns (bytes4) {
        console.log("beforeRemoveLiquidity middleware");
        (bool success, bytes memory returnData) = implementation.delegatecall{gas: gasLimit}(msg.data);
        console.log(success);
        return BaseHook.beforeRemoveLiquidity.selector;
    }

    function afterRemoveLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        BalanceDelta,
        bytes calldata
    ) external returns (bytes4, BalanceDelta) {
        console.log("afterRemoveLiquidity middleware");
        (bool success, bytes memory returnData) = implementation.delegatecall{gas: gasLimit}(msg.data);
        console.log(success);
        // hook cannot return delta
        return (BaseHook.afterRemoveLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }
}
