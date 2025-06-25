// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IWrappedPermissionedToken, IERC20} from "./interfaces/IWrappedPermissionedToken.sol";
import {IAllowlistChecker} from "./interfaces/IAllowlistChecker.sol";
import {WrappedPermissionedToken} from "./WrappedPermissionedToken.sol";
import {IWrappedPermissionedTokenFactory} from "./interfaces/IWrappedPermissionedTokenFactory.sol";

contract WrappedPermissionedTokenFactory is IWrappedPermissionedTokenFactory {
    address public immutable POOL_MANAGER;

    /// @inheritdoc IWrappedPermissionedTokenFactory
    mapping(address wrappedToken => address permissionedToken) public permissionedTokenOf;
    /// @inheritdoc IWrappedPermissionedTokenFactory
    mapping(address wrappedToken => address permissionedToken) public verifiedPermissionedTokenOf;

    constructor(address poolManager) {
        POOL_MANAGER = poolManager;
    }

    /// @inheritdoc IWrappedPermissionedTokenFactory
    function createWrappedPermissionedToken(
        IERC20 permissionedToken,
        address initialOwner,
        IAllowlistChecker allowListChecker
    ) external returns (address wrappedPermissionedToken) {
        wrappedPermissionedToken =
            address(new WrappedPermissionedToken(permissionedToken, POOL_MANAGER, initialOwner, allowListChecker));
        permissionedTokenOf[wrappedPermissionedToken] = address(permissionedToken);
        emit WrappedPermissionedTokenCreated(wrappedPermissionedToken, address(permissionedToken));
    }

    /// @inheritdoc IWrappedPermissionedTokenFactory
    function verifyWrappedToken(address wrappedToken) external {
        IERC20 permissionedToken = IERC20(permissionedTokenOf[wrappedToken]);
        if (address(permissionedToken) == address(0)) revert WrappedTokenNotFound(wrappedToken);
        if (verifiedPermissionedTokenOf[wrappedToken] != address(0)) revert WrappedTokenAlreadyVerified(wrappedToken);
        if (permissionedToken.balanceOf(wrappedToken) == 0) revert WrappedTokenNotVerified(wrappedToken);
        verifiedPermissionedTokenOf[wrappedToken] = address(permissionedToken);
        emit WrappedTokenVerified(wrappedToken, address(permissionedToken));
    }
}
