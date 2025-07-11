// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IAllowlistChecker, PermissionFlag} from "./IAllowlistChecker.sol";

interface IWrappedPermissionedToken is IERC20 {
    /// @notice Emitted when the allow list checker is updated
    event AllowListCheckerUpdated(IAllowlistChecker indexed newAllowListChecker);

    /// @notice Emitted when an allowed wrapper is updated
    event AllowedWrapperUpdated(address indexed wrapper, bool allowed);

    /// @notice Emitted when an allowed hook is updated
    event AllowedHookUpdated(address indexed positionManager, IHooks indexed hooks, bool allowed);

    /// @notice Thrown when the allow list checker does not implement the IAllowListChecker interface
    error InvalidAllowListChecker(IAllowlistChecker newAllowListChecker);

    /// @notice Thrown when the transfer is not interacting with the pool manager
    error InvalidTransfer(address from, address to);

    /// @notice Thrown when the wrapper is not allowed to trigger transfers on the wrapped token
    error UnauthorizedWrapper(address wrapper);

    /// @notice Thrown when there is an insufficient amount of permissioned tokens available to wrap
    error InsufficientBalance(uint256 amount, uint256 availableBalance);

    /// @notice Updates the allow list checker
    /// @param newAllowListChecker The new allow list checker
    /// @dev Only callable by the owner
    function updateAllowListChecker(IAllowlistChecker newAllowListChecker) external;

    /// @notice Wraps the permissioned token to the pool manager
    /// @param amount The amount of permissioned tokens to wrap
    /// @dev Only callable by allowed wrappers
    /// @dev The `amount` must be sent to this contract before calling this function
    function wrapToPoolManager(uint256 amount) external;

    /// @notice Updates the allowed wrapper that can wrap the permissioned token
    /// @param wrapper The wrapper to update
    /// @param allowed Whether the wrapper is allowed
    /// @dev Only callable by the owner
    /// @dev To ensure the wrapped token cannot be wrapped in an ERC6909 token on the PoolManager, the wrapper must only implement `swap` or `modifyLiquidity` functions
    function updateAllowedWrapper(address wrapper, bool allowed) external;

    /// @notice Returns whether a transfer is allowed
    /// @param account The account to check
    function isAllowed(address account, PermissionFlag permission) external view returns (bool);

    /// @notice Returns whether a hook is allowed
    /// @param hooks The hook to check
    function isAllowedHook(address positionManager, IHooks hooks) external view returns (bool);

    /// @notice Sets whether a hook is allowed
    /// @param hooks The hook to set
    /// @param allowed Whether the hook is allowed
    /// @dev Only callable by the owner
    function setAllowedHook(address positionManager, IHooks hooks, bool allowed) external;

    /// @notice Returns the allow list checker
    function allowListChecker() external view returns (IAllowlistChecker);

    /// @notice Returns the allowed wrappers that can wrap the permissioned token
    /// @dev e.g., the permissioned pool manager, quoters or the swap router
    function allowedWrappers(address wrapper) external view returns (bool);

    /// @notice Returns the Uniswap v4 pool manager
    function POOL_MANAGER() external view returns (address);

    /// @notice Returns the permissioned token that is wrapped by this contract
    function PERMISSIONED_TOKEN() external view returns (IERC20);

    /// @notice Returns the admin of the wrapped permissioned token
    function owner() external view returns (address);
}
