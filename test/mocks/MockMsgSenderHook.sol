// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BaseTestHooks} from "@uniswap/v4-core/src/test/BaseTestHooks.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {IMsgSender} from "../../src/interfaces/IMsgSender.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

contract MockMsgSenderHook is BaseTestHooks {
    event BeforeSwapMsgSender(address msgSender);
    event AfterSwapMsgSender(address msgSender);

    function beforeSwap(address periphery, PoolKey calldata, SwapParams calldata, bytes calldata)
        external
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        emit BeforeSwapMsgSender(IMsgSender(periphery).msgSender());
        return (BaseTestHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    function afterSwap(address periphery, PoolKey calldata, SwapParams calldata, BalanceDelta, bytes calldata)
        external
        override
        returns (bytes4, int128)
    {
        emit AfterSwapMsgSender(IMsgSender(periphery).msgSender());
        return (BaseTestHooks.afterSwap.selector, 0);
    }
}
