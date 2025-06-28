// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {IPoolManager, IAllowanceTransfer, IPositionDescriptor, IWETH9} from "../../PositionManager.sol";
import {IWrappedPermissionedTokenFactory} from "./interfaces/IWrappedPermissionedTokenFactory.sol";
import {PermissionedPositionManager} from "./PermissionedPositionManager.sol";

contract BasePermissionedPositionManager is PermissionedPositionManager {
    constructor(
        IPoolManager _poolManager,
        IAllowanceTransfer _permit2,
        uint256 _unsubscribeGasLimit,
        IPositionDescriptor _tokenDescriptor,
        IWETH9 _weth9,
        IWrappedPermissionedTokenFactory _wrappedTokenFactory,
        address _permissionedSwapRouter
    )
        PermissionedPositionManager(
            _poolManager,
            _permit2,
            _unsubscribeGasLimit,
            _tokenDescriptor,
            _weth9,
            _wrappedTokenFactory,
            _permissionedSwapRouter
        )
    {}
}
