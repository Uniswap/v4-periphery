// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PermissionedV4Router} from "../../../../src/hooks/permissionedPools/PermissionedV4Router.sol";
import {SafeTransferLib} from "solmate/src/utils/SafeTransferLib.sol";
import {ERC20} from "solmate/src/tokens/ERC20.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {IWrappedPermissionedTokenFactory} from
    "../../../../src/hooks/permissionedPools/interfaces/IWrappedPermissionedTokenFactory.sol";

contract MockPermissionedV4Router is PermissionedV4Router {
    using SafeTransferLib for *;

    constructor(
        IPoolManager poolManager_,
        IAllowanceTransfer _permit2,
        IWrappedPermissionedTokenFactory wrappedTokenFactory,
        address permissionedPositionManager
    ) PermissionedV4Router(poolManager_, _permit2, wrappedTokenFactory, permissionedPositionManager) {}

    function executeActions(bytes calldata params) external payable isNotLocked {
        _executeActions(params);
    }

    function executeActionsAndSweepExcessETH(bytes calldata params) external payable isNotLocked {
        _executeActions(params);

        uint256 balance = address(this).balance;
        if (balance > 0) {
            msg.sender.safeTransferETH(balance);
        }
    }

    receive() external payable {}
    fallback() external payable {}
}
