// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ISubscriber} from "../../src/interfaces/ISubscriber.sol";
import {INotifier} from "../../src/interfaces/INotifier.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PositionInfo} from "../../src/libraries/PositionInfoLibrary.sol";

/// @notice On `notifyUnsubscribe`, re-attaches a fresh subscriber via `posm.subscribe(...)`.
///         `unwindPosition` unsubscribes with the manager locked, so `subscribe`'s
///         `onlyIfPoolManagerLocked` guard passes and the re-attach succeeds; used to verify that
///         `unwindPosition`'s force-clear removes the re-attached subscriber before the burn.
contract MockReentrantSubscriber is ISubscriber {
    INotifier public immutable posm;
    address public immutable reentrantTarget;

    constructor(INotifier _posm, address _reentrantTarget) {
        posm = _posm;
        reentrantTarget = _reentrantTarget;
    }

    function notifySubscribe(uint256, bytes memory) external pure {}

    function notifyUnsubscribe(uint256 tokenId) external {
        // The manager is locked here, so subscribe's onlyIfPoolManagerLocked guard passes and this
        // re-attach succeeds; unwindPosition's force-clear removes it before BURN_POSITION.
        posm.subscribe(tokenId, reentrantTarget, "");
    }

    function notifyModifyLiquidity(uint256, int256, BalanceDelta) external pure {}

    function notifyBurn(uint256, address, PositionInfo, uint256, BalanceDelta) external pure {}
}
