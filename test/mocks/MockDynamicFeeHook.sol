// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {BaseTestHooks} from "@uniswap/v4-core/src/test/BaseTestHooks.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";

/// @dev Dynamic-fee test hook that also requires an exact hookData payload on every swap.
contract MockDynamicFeeHook is BaseTestHooks {
    error UnexpectedHookData();

    uint24 public overrideFee;
    bytes32 public expectedHookDataHash;
    uint256 public beforeSwapCalls;

    function configure(bytes calldata expectedHookData, uint24 fee) external {
        expectedHookDataHash = keccak256(expectedHookData);
        overrideFee = fee;
    }

    function setFee(uint24 fee) external {
        overrideFee = fee;
    }

    function beforeSwap(address, PoolKey calldata, SwapParams calldata, bytes calldata hookData)
        external
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        if (keccak256(hookData) != expectedHookDataHash) revert UnexpectedHookData();
        beforeSwapCalls++;
        return
            (
                IHooks.beforeSwap.selector,
                BeforeSwapDeltaLibrary.ZERO_DELTA,
                overrideFee | LPFeeLibrary.OVERRIDE_FEE_FLAG
            );
    }
}
