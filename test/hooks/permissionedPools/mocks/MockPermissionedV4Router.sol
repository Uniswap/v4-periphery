// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {PermissionedV4Router} from "../../../../src/hooks/permissionedPools/PermissionedV4Router.sol";
import {IWrappedPermissionedTokenFactory} from
    "../../../../src/hooks/permissionedPools/interfaces/IWrappedPermissionedTokenFactory.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {SafeTransferLib} from "solmate/src/utils/SafeTransferLib.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";

contract MockPermissionedV4Router is PermissionedV4Router {
    using SafeTransferLib for *;

    constructor(
        IPoolManager poolManager_,
        IAllowanceTransfer permit2,
        IWrappedPermissionedTokenFactory wrappedTokenFactory,
        address permissionedPositionManager,
        address permissionedHooks
    )
        PermissionedV4Router(poolManager_, permit2, wrappedTokenFactory, permissionedPositionManager, permissionedHooks)
    {}

    function executeActionsAndSweepExcessETH(bytes calldata params) external payable isNotLocked {
        execute(params);
        uint256 balance = address(this).balance;
        if (balance > 0) {
            msg.sender.safeTransferETH(balance);
        }
    }

    receive() external payable {}
    fallback() external payable {}
}
