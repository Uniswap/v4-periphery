// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IERC20} from "./IPermissionsAdapter.sol";
import {IAllowlistChecker} from "./IAllowlistChecker.sol";

interface IPermissionsAdapterFactory {
    /// @notice Emitted when a permissions adapter is created
    event PermissionsAdapterCreated(address indexed permissionsAdapter, address indexed permissionedToken);

    /// @notice Emitted when a permissions adapter is verified
    event PemissionsAdapterVerified(address indexed permissionsAdapter, address indexed permissionedToken);

    /// @notice Thrown when the permissions adapter does not exist
    error PermissionsAdapterNotFound(address permissionsAdapter);

    /// @notice Thrown when the permissions adapter is already verified
    error PemissionsAdapterAlreadyVerified(address permissionsAdapter);

    /// @notice Thrown when the permissions adapter is not verified
    error PemissionsAdapterNotVerified(address permissionsAdapter);

    /// @notice Creates a new permissions adapter
    /// @param permissionedToken The permissioned token to wrap
    /// @param initialOwner The initial owner of the permissions adapter
    /// @param allowListChecker The allow list checker that will be used to check if transfers are allowed
    function createPermissionsAdapter(
        IERC20 permissionedToken,
        address initialOwner,
        IAllowlistChecker allowListChecker
    ) external returns (address);

    /// @notice Verifies a permissions adapter
    /// @param permissionsAdapter The permissions adapter
    /// @dev This function verifies that the permissions adapter has a balance of the permissioned token. This means that the permissions adapter is on the allow list of the permissioned token and can be used to wrap and unwrap the permissioned token.
    function verifyPermissionsAdapter(address permissionsAdapter) external;

    /// @notice Returns the permissioned token of a permissions adapter
    /// @param permissionsAdapter The permissions adapter
    /// @return permissionedToken The permissioned token
    function permissionsAdapterOf(address permissionsAdapter) external view returns (address permissionedToken);

    /// @notice Returns the verified permissioned token of a permissions adapter
    /// @param permissionsAdapter The permissions adapter
    /// @return permissionedToken The verified permissioned token
    /// @dev A reverse lookup of the permissioned token is required, otherwise anyone could create a permissions adapter for a non-permissioned token
    function verifiedPermissionsAdapterOf(address permissionsAdapter) external view returns (address permissionedToken);

    /// @notice Returns the v4 pool manager
    /// @return poolManager The v4 pool manager
    function POOL_MANAGER() external view returns (address poolManager);
}
