// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC721} from "forge-std/interfaces/IERC721.sol";
import {ISubscriber} from "../../src/interfaces/ISubscriber.sol";
import {INotifier} from "../../src/interfaces/INotifier.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PositionInfo} from "../../src/libraries/PositionInfoLibrary.sol";

/// @notice Subscriber that overwrites `getApproved[tokenId]` during `notifyUnsubscribe`.
/// @dev `approve` carries no `onlyIfPoolManagerLocked` guard, so the write lands even from inside an
///      active unlock callback. Two attacker shapes both satisfy `ERC721Permit_v4.approve`'s auth check:
///      the subscriber IS the owner (a contract LP subscribing itself), or it holds `setApprovalForAll`.
///      Must return cleanly — `_unsubscribe` wraps the callback in try/catch, so reverting would roll the
///      hijacking SSTORE back. Set `approveTarget` to the admin to write the same value back, isolating the
///      written value rather than the act of reentering, and `approveDuringCallback = false` for a
///      behaviourally benign control.
contract MockApprovalHijackSubscriber is ISubscriber {
    IERC721 public immutable posm;
    bool public immutable approveDuringCallback;
    /// @dev `address(0)` is a sentinel meaning "approve myself".
    address public immutable approveTarget;

    uint256 public notifyUnsubscribeCount;
    uint256 public gasUsedByApprove;

    constructor(address _posm, bool _approveDuringCallback, address _approveTarget) {
        posm = IERC721(_posm);
        approveDuringCallback = _approveDuringCallback;
        approveTarget = _approveTarget;
    }

    /// @notice Used by the contract-LP shape, where the subscriber is itself the position owner.
    function subscribeSelf(uint256 tokenId) external {
        INotifier(address(posm)).subscribe(tokenId, address(this), "");
    }

    function notifySubscribe(uint256, bytes memory) external {}

    function notifyUnsubscribe(uint256 tokenId) external {
        if (approveDuringCallback) {
            uint256 gasBefore = gasleft();
            posm.approve(approveTarget == address(0) ? address(this) : approveTarget, tokenId);
            gasUsedByApprove = gasBefore - gasleft();
        }
        notifyUnsubscribeCount++;
    }

    function notifyModifyLiquidity(uint256, int256, BalanceDelta) external {}

    function notifyBurn(uint256, address, PositionInfo, uint256, BalanceDelta) external {}
}
