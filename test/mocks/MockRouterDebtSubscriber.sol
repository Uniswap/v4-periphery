// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";

import {ISubscriber} from "../../src/interfaces/ISubscriber.sol";
import {PositionInfo} from "../../src/libraries/PositionInfoLibrary.sol";
import {IUniversalRouter} from "../../src/interfaces/external/IUniversalRouter.sol";

/// @dev Subscriber that runs `route` on the Universal Router on its first liquidity notification,
///      planting router debt. Inert until armed.
contract MockRouterDebtSubscriber is ISubscriber {
    IUniversalRouter public router;
    bytes public route;
    bool public armed;

    function arm(IUniversalRouter _router, bytes calldata _route) external {
        router = _router;
        route = _route;
        armed = true;
    }

    function notifySubscribe(uint256, bytes memory) external {}

    function notifyUnsubscribe(uint256) external {}

    function notifyBurn(uint256, address, PositionInfo, uint256, BalanceDelta) external {}

    function notifyModifyLiquidity(uint256, int256, BalanceDelta) external {
        if (!armed) return;
        armed = false;
        (bytes memory commands, bytes[] memory inputs) = abi.decode(route, (bytes, bytes[]));
        router.execute(commands, inputs);
    }
}
