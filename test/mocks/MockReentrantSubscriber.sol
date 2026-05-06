// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ISubscriber} from "../../src/interfaces/ISubscriber.sol";
import {INotifier} from "../../src/interfaces/INotifier.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PositionInfo} from "../../src/libraries/PositionInfoLibrary.sol";

/// @notice On `notifyUnsubscribe`, attempts to re-attach a fresh subscriber via
///         `posm.subscribe(...)`. Used to verify that the re-entry is blocked by the
///         existing `onlyIfPoolManagerLocked` guard on `subscribe` when `unsubscribe`
///         runs from inside an unlock callback.
contract MockReentrantSubscriber is ISubscriber {
    INotifier public immutable posm;
    address public immutable reentrantTarget;

    constructor(INotifier _posm, address _reentrantTarget) {
        posm = _posm;
        reentrantTarget = _reentrantTarget;
    }

    function notifySubscribe(uint256, bytes memory) external pure {}

    function notifyUnsubscribe(uint256 tokenId) external {
        // Should revert with PoolManagerMustBeLocked when called from inside an active
        // unlock callback — that's the protection we're testing.
        posm.subscribe(tokenId, reentrantTarget, "");
    }

    function notifyModifyLiquidity(uint256, int256, BalanceDelta) external pure {}

    function notifyBurn(uint256, address, PositionInfo, uint256, BalanceDelta) external pure {}
}
