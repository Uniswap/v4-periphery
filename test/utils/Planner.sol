// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {INonfungiblePositionManager, Actions} from "../../contracts/interfaces/INonfungiblePositionManager.sol";
import {LiquidityRange} from "../../contracts/types/LiquidityRange.sol";

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

    function finalize(Plan memory plan, LiquidityRange memory range) internal pure returns (Plan memory) {
        plan = plan.add(Actions.CLOSE_CURRENCY, abi.encode(range.poolKey.currency0));
        plan = plan.add(Actions.CLOSE_CURRENCY, abi.encode(range.poolKey.currency1));
        return plan;
    }

    function zip(Plan memory plan) internal returns (bytes memory) {
        return abi.encode(plan.actions, plan.params);
    }
}
