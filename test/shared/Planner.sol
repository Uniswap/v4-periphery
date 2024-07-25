// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

import {IPositionManager, Actions} from "../../src/interfaces/IPositionManager.sol";

library Planner {
    using Planner for Plan;

    struct Plan {
        Actions[] actions;
        bytes[] params;
    }

    function init() internal pure returns (Plan memory plan) {
        return Plan({actions: new Actions[](0), params: new bytes[](0)});
    }

    function add(Plan memory plan, Actions action, bytes memory param) internal pure returns (Plan memory) {
        Actions[] memory actions = new Actions[](plan.actions.length + 1);
        bytes[] memory params = new bytes[](plan.params.length + 1);

        for (uint256 i; i < actions.length - 1; i++) {
            // Copy from plan.
            actions[i] = plan.actions[i];
            params[i] = plan.params[i];
        }

        actions[actions.length - 1] = action;
        params[params.length - 1] = param;

        return Plan({actions: actions, params: params});
    }

    function finalize(Plan memory plan, PoolKey memory poolKey) internal pure returns (bytes memory) {
        plan = plan.add(Actions.CLOSE_CURRENCY, abi.encode(poolKey.currency0));
        plan = plan.add(Actions.CLOSE_CURRENCY, abi.encode(poolKey.currency1));
        return plan.encode();
    }

    function encode(Plan memory plan) internal pure returns (bytes memory) {
        return abi.encode(plan.actions, plan.params);
    }
}
