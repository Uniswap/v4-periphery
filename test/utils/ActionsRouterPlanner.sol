// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

struct Plan {
    uint256[] actions;
    bytes[] params;
}

library ActionsRouterPlanner {
    function init() internal pure returns (Plan memory plan) {
        return Plan({actions: new uint256[](0), params: new bytes[](0)});
    }

    function add(Plan memory plan, uint256 action, bytes memory param) internal pure returns (Plan memory) {
        uint256[] memory actions = new uint256[](plan.actions.length + 1);
        bytes[] memory params = new bytes[](plan.params.length + 1);

        for (uint256 i; i < actions.length - 1; i++) {
            // Copy from plan.
            actions[i] = plan.actions[i];
            params[i] = plan.params[i];
        }

        actions[actions.length - 1] = action;
        params[params.length - 1] = param;

        plan.actions = actions;
        plan.params = params;

        return plan;
    }

    function encode(Plan memory plan) internal pure returns (bytes memory) {
        return abi.encode(plan.actions, plan.params);
    }
}
