// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ISubscriber} from "../../src/interfaces/ISubscriber.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PositionInfo} from "../../src/libraries/PositionInfoLibrary.sol";

/// @notice Subscriber that reverts only on `notifyBurn`. Used to verify that LP-initiated
///         burns still propagate the revert (base behavior is preserved).
contract MockBurnRevertingSubscriber is ISubscriber {
    error TestRevert(string);

    function notifySubscribe(uint256, bytes memory) external pure {}

    function notifyUnsubscribe(uint256) external pure {}

    function notifyModifyLiquidity(uint256, int256, BalanceDelta) external pure {}

    function notifyBurn(uint256, address, PositionInfo, uint256, BalanceDelta) external pure {
        revert TestRevert("notifyBurn");
    }
}
