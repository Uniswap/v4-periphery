// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

import {Actions} from "../../src/libraries/Actions.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {ActionConstants} from "../../src/libraries/ActionConstants.sol";

struct Plan {
    bytes actions;
    bytes[] params;
}

using Planner for Plan global;

library Planner {
    function init() internal pure returns (Plan memory plan) {
        return Plan({actions: bytes(""), params: new bytes[](0)});
    }

    function add(Plan memory plan, uint256 action, bytes memory param) internal pure returns (Plan memory) {
        bytes memory actions = new bytes(plan.params.length + 1);
        bytes[] memory params = new bytes[](plan.params.length + 1);

        for (uint256 i; i < params.length - 1; i++) {
            // Copy from plan.
            params[i] = plan.params[i];
            actions[i] = plan.actions[i];
        }
        params[params.length - 1] = param;
        actions[params.length - 1] = bytes1(uint8(action));

        plan.actions = actions;
        plan.params = params;

        return plan;
    }

    function finalizeModifyLiquidityWithTake(Plan memory plan, PoolKey memory poolKey, address takeRecipient)
        internal
        pure
        returns (bytes memory)
    {
        plan.add(Actions.TAKE, abi.encode(poolKey.currency0, takeRecipient, ActionConstants.OPEN_DELTA));
        plan.add(Actions.TAKE, abi.encode(poolKey.currency1, takeRecipient, ActionConstants.OPEN_DELTA));
        return plan.encode();
    }

    function finalizeModifyLiquidityWithClose(Plan memory plan, PoolKey memory poolKey)
        internal
        pure
        returns (bytes memory)
    {
        plan.add(Actions.CLOSE_CURRENCY, abi.encode(poolKey.currency0));
        plan.add(Actions.CLOSE_CURRENCY, abi.encode(poolKey.currency1));
        return plan.encode();
    }

    function finalizeModifyLiquidityWithSettlePair(Plan memory plan, PoolKey memory poolKey)
        internal
        pure
        returns (bytes memory)
    {
        plan.add(Actions.SETTLE_PAIR, abi.encode(poolKey.currency0, poolKey.currency1));
        return plan.encode();
    }

    function finalizeModifyLiquidityWithTakePair(Plan memory plan, PoolKey memory poolKey, address takeRecipient)
        internal
        pure
        returns (bytes memory)
    {
        plan.add(Actions.TAKE_PAIR, abi.encode(poolKey.currency0, poolKey.currency1, takeRecipient));
        return plan.encode();
    }

    function encode(Plan memory plan) internal pure returns (bytes memory) {
        return abi.encode(plan.actions, plan.params);
    }

    function finalizeSwap(Plan memory plan, Currency inputCurrency, Currency outputCurrency, address takeRecipient)
        internal
        pure
        returns (bytes memory)
    {
        if (takeRecipient == ActionConstants.MSG_SENDER) {
            // blindly settling and taking all, without slippage checks, isnt recommended in prod
            plan = plan.add(Actions.SETTLE_ALL, abi.encode(inputCurrency, type(uint256).max));
            plan = plan.add(Actions.TAKE_ALL, abi.encode(outputCurrency, 0));
        } else {
            plan = plan.add(Actions.SETTLE, abi.encode(inputCurrency, ActionConstants.OPEN_DELTA, true));
            plan = plan.add(Actions.TAKE, abi.encode(outputCurrency, takeRecipient, ActionConstants.OPEN_DELTA));
        }
        return plan.encode();
    }
}
