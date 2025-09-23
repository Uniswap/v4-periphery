// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPermissionsAdapter, IERC20} from "./interfaces/IPermissionsAdapter.sol";
import {IAllowlistChecker} from "./interfaces/IAllowlistChecker.sol";
import {PermissionsAdapter} from "./PermissionsAdapter.sol";
import {IPermissionsAdapterFactory} from "./interfaces/IPermissionsAdapterFactory.sol";

contract PermissionsAdapterFactory is IPermissionsAdapterFactory {
    address public immutable POOL_MANAGER;

    /// @inheritdoc IPermissionsAdapterFactory
    mapping(address permissionsAdapter => address permissionedToken) public permissionsAdapterOf;
    /// @inheritdoc IPermissionsAdapterFactory
    mapping(address permissionsAdapter => address permissionedToken) public verifiedPermissionsAdapterOf;

    constructor(address poolManager) {
        POOL_MANAGER = poolManager;
    }

    /// @inheritdoc IPermissionsAdapterFactory
    function createPermissionsAdapter(
        IERC20 permissionedToken,
        address initialOwner,
        IAllowlistChecker allowListChecker
    ) external returns (address permissionsAdapter) {
        permissionsAdapter =
            address(new PermissionsAdapter(permissionedToken, POOL_MANAGER, initialOwner, allowListChecker));
        permissionsAdapterOf[permissionsAdapter] = address(permissionedToken);
        emit PermissionsAdapterCreated(permissionsAdapter, address(permissionedToken));
    }

    /// @inheritdoc IPermissionsAdapterFactory
    function verifyPermissionsAdapter(address permissionsAdapter) external {
        IERC20 permissionedToken = IERC20(permissionsAdapterOf[permissionsAdapter]);
        if (address(permissionedToken) == address(0)) revert PemissionsAdapterNotFound(permissionsAdapter);
        if (verifiedPermissionsAdapterOf[permissionsAdapter] != address(0)) {
            revert PemissionsAdapterAlreadyVerified(permissionsAdapter);
        }
        // this requires that the verifier has some comntrol or ownership of the permissioned token
        if (permissionedToken.balanceOf(permissionsAdapter) == 0) {
            revert PemissionsAdapterNotVerified(permissionsAdapter);
        }
        verifiedPermissionsAdapterOf[permissionsAdapter] = address(permissionedToken);
        emit PemissionsAdapterVerified(permissionsAdapter, address(permissionedToken));
    }
}
