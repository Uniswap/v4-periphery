// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPermissionsAdapter, IERC20} from "./interfaces/IPermissionsAdapter.sol";
import {IAllowlistChecker} from "./interfaces/IAllowlistChecker.sol";
import {PermissionsAdapter} from "./PermissionsAdapter.sol";
import {IPermissionsAdapterFactory} from "./interfaces/IPermissionsAdapterFactory.sol";

contract PermissionsAdapterFactory is IPermissionsAdapterFactory {
    address public immutable POOL_MANAGER;

    /// @inheritdoc IPermissionsAdapterFactory
    mapping(address pemissionsAdapter => address permissionedToken) public permissionsAdapterOf;
    /// @inheritdoc IPermissionsAdapterFactory
    mapping(address pemissionsAdapter => address permissionedToken) public verifiedPermissionsAdapterOf;

    constructor(address poolManager) {
        POOL_MANAGER = poolManager;
    }

    /// @inheritdoc IPermissionsAdapterFactory
    function createPermissionsAdapter(
        IERC20 permissionedToken,
        address initialOwner,
        IAllowlistChecker allowListChecker
    ) external returns (address pemissionsAdapter) {
        pemissionsAdapter =
            address(new PermissionsAdapter(permissionedToken, POOL_MANAGER, initialOwner, allowListChecker));
        permissionsAdapterOf[pemissionsAdapter] = address(permissionedToken);
        emit PermissionsAdapterCreated(pemissionsAdapter, address(permissionedToken));
    }

    /// @inheritdoc IPermissionsAdapterFactory
    function verifyPermissionsAdapter(address pemissionsAdapter) external {
        IERC20 permissionedToken = IERC20(permissionsAdapterOf[pemissionsAdapter]);
        if (address(permissionedToken) == address(0)) revert PemissionsAdapterNotFound(pemissionsAdapter);
        if (verifiedPermissionsAdapterOf[pemissionsAdapter] != address(0)) {
            revert PemissionsAdapterAlreadyVerified(pemissionsAdapter);
        }
        // this requires that the verifier has some comntrol or ownership of the permissioned token
        if (permissionedToken.balanceOf(pemissionsAdapter) == 0) revert PemissionsAdapterNotVerified(pemissionsAdapter);
        verifiedPermissionsAdapterOf[pemissionsAdapter] = address(permissionedToken);
        emit PemissionsAdapterVerified(pemissionsAdapter, address(permissionedToken));
    }
}
