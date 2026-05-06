// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ISubscriber} from "../../src/interfaces/ISubscriber.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PositionInfo} from "../../src/libraries/PositionInfoLibrary.sol";

/// @notice Subscriber that reverts only on `notifyUnsubscribe`. Used to verify that
///         admin force-exit (`unwindPosition`) swallows the revert via the existing
///         gas-capped + try/catch path on `_unsubscribe`.
contract MockUnsubscribeRevertingSubscriber is ISubscriber {
    error TestRevert(string);

    function notifySubscribe(uint256, bytes memory) external pure {}

    function notifyUnsubscribe(uint256) external pure {
        revert TestRevert("notifyUnsubscribe");
    }

    function notifyModifyLiquidity(uint256, int256, BalanceDelta) external pure {}

    function notifyBurn(uint256, address, PositionInfo, uint256, BalanceDelta) external pure {}
}
