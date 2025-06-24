// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IWrappedPermissionedToken, IERC20} from "./IWrappedPermissionedToken.sol";
import {IAllowlistChecker} from "./IAllowlistChecker.sol";

interface IWrappedPermissionedTokenFactory {
    /// @notice Emitted when a wrapped permissioned token is created
    event WrappedPermissionedTokenCreated(address indexed wrappedToken, address indexed permissionedToken);

    /// @notice Emitted when a wrapped permissioned token is verified
    event WrappedTokenVerified(address indexed wrappedToken, address indexed permissionedToken);

    /// @notice Thrown when the wrapped token does not exist
    error WrappedTokenNotFound(address wrappedToken);

    /// @notice Thrown when the wrapped token is already verified
    error WrappedTokenAlreadyVerified(address wrappedToken);

    /// @notice Thrown when the wrapped token is not verified
    error WrappedTokenNotVerified(address wrappedToken);

    /// @notice Creates a new wrapped permissioned token
    /// @param permissionedToken The permissioned token to wrap
    /// @param initialOwner The initial owner of the wrapped permissioned token
    /// @param allowListChecker The allow list checker that will be used to check if transfers are allowed
    function createWrappedPermissionedToken(
        IERC20 permissionedToken,
        address initialOwner,
        IAllowlistChecker allowListChecker
    ) external returns (address);

    /// @notice Verifies a wrapped permissioned token
    /// @param wrappedToken The wrapped permissioned token
    /// @dev This function verifies that the wrapped token has a balance of the permissioned token. This means that the wrapped token is on the allow list of the permissioned token and can be used to wrap and unwrap the permissioned token.
    function verifyWrappedToken(address wrappedToken) external;

    /// @notice Returns the permissioned token of a wrapped permissioned token
    /// @param wrappedToken The wrapped permissioned token
    /// @return permissionedToken The permissioned token
    function permissionedTokenOf(address wrappedToken) external view returns (address permissionedToken);

    /// @notice Returns the verified permissioned token of a wrapped permissioned token
    /// @param wrappedToken The wrapped permissioned token
    /// @return permissionedToken The verified permissioned token
    /// @dev A reverse lookup of the permissioned token is required, otherwise anyone could create a wrapped token for a non-permissioned token
    function verifiedPermissionedTokenOf(address wrappedToken) external view returns (address permissionedToken);

    /// @notice Returns the v4 pool manager
    /// @return poolManager The v4 pool manager
    function POOL_MANAGER() external view returns (address poolManager);
}
