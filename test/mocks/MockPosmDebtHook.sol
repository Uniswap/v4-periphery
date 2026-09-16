// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {BaseTestHooks} from "@uniswap/v4-core/src/test/BaseTestHooks.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";

import {IPositionManager} from "../../src/interfaces/IPositionManager.sol";
import {Actions} from "../../src/libraries/Actions.sol";
import {ActionConstants} from "../../src/libraries/ActionConstants.sol";

/// @dev beforeSwap-only hook. When armed, drives POSM's PoolManager delta negative in `currency`
///      via an unauthenticated TAKE to itself, then disarms.
contract MockPosmDebtHook is BaseTestHooks {
    IPositionManager public positionManager;
    Currency public currency;
    uint256 public amount;
    bool public armed;

    function arm(IPositionManager _positionManager, Currency _currency, uint256 _amount) external {
        positionManager = _positionManager;
        currency = _currency;
        amount = _amount;
        armed = true;
    }

    function beforeSwap(address, PoolKey calldata, SwapParams calldata, bytes calldata)
        external
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        if (armed) {
            armed = false;
            bytes[] memory params = new bytes[](1);
            params[0] = abi.encode(currency, ActionConstants.MSG_SENDER, amount);
            positionManager.modifyLiquiditiesWithoutUnlock(abi.encodePacked(uint8(Actions.TAKE)), params);
        }
        return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }
}
