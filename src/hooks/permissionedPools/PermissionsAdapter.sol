// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IPermissionsAdapter} from "./interfaces/IPermissionsAdapter.sol";
import {IAllowlistChecker} from "./interfaces/IAllowlistChecker.sol";
import {PermissionFlag} from "./libraries/PermissionFlags.sol";

contract PermissionsAdapter is ERC20, Ownable2Step, IPermissionsAdapter {
    /// @inheritdoc IPermissionsAdapter
    address public immutable POOL_MANAGER;

    /// @inheritdoc IPermissionsAdapter
    IERC20 public immutable PERMISSIONED_TOKEN;

    /// @inheritdoc IPermissionsAdapter
    IAllowlistChecker public allowListChecker;

    /// @inheritdoc IPermissionsAdapter
    bool public swappingEnabled;

    /// @inheritdoc IPermissionsAdapter
    mapping(address wrapper => bool) public allowedWrappers;

    constructor(
        IERC20 permissionedToken,
        address poolManager,
        address initialOwner,
        IAllowlistChecker allowListChecker_
    ) ERC20(_getName(permissionedToken), _getSymbol(permissionedToken)) Ownable(initialOwner) {
        PERMISSIONED_TOKEN = permissionedToken;
        POOL_MANAGER = poolManager;
        _updateAllowListChecker(allowListChecker_);
    }

    /// @inheritdoc IPermissionsAdapter
    function wrapToPoolManager(uint256 amount) external {
        if (!allowedWrappers[msg.sender]) revert UnauthorizedWrapper(msg.sender);
        uint256 availableBalance = PERMISSIONED_TOKEN.balanceOf(address(this)) - totalSupply();
        if (amount > availableBalance) revert InsufficientBalance(amount, availableBalance);
        _mint(POOL_MANAGER, amount);
    }

    /// @inheritdoc IPermissionsAdapter
    function updateAllowListChecker(IAllowlistChecker newAllowListChecker) external onlyOwner {
        _updateAllowListChecker(newAllowListChecker);
    }

    /// @inheritdoc IPermissionsAdapter
    function updateAllowedWrapper(address wrapper, bool allowed) external onlyOwner {
        _updateAllowedWrapper(wrapper, allowed);
    }

    /// @inheritdoc IPermissionsAdapter
    function updateSwappingEnabled(bool enabled) external onlyOwner {
        _updateSwappingEnabled(enabled);
    }

    /// @inheritdoc IPermissionsAdapter
    function isAllowed(address account, PermissionFlag permission) public view returns (bool) {
        return ((allowListChecker.checkAllowlist(account)) & (permission)) == (permission);
    }

    function _updateAllowListChecker(IAllowlistChecker newAllowListChecker) internal {
        if (!newAllowListChecker.supportsInterface(type(IAllowlistChecker).interfaceId)) {
            revert InvalidAllowListChecker(newAllowListChecker);
        }
        allowListChecker = newAllowListChecker;
        emit AllowListCheckerUpdated(newAllowListChecker);
    }

    function _updateAllowedWrapper(address wrapper, bool allowed) internal {
        allowedWrappers[wrapper] = allowed;
        emit AllowedWrapperUpdated(wrapper, allowed);
    }

    function _updateSwappingEnabled(bool enabled) internal {
        swappingEnabled = enabled;
        emit SwappingEnabledUpdated(enabled);
    }

    /// @dev Overrides the ERC20._update function to add the following checks and logic:
    /// - Before `settle` is called on the pool manager, the permissioned token is deposited and the permissions adapter is minted to the pool manager
    /// - When `take` is called on the pool manager, the permissioned token is automatically released when the pool manager transfers the permissions adapter to the recipient
    /// - Enforces that the pool manager is the only holder of the permissions adapter
    function _update(address from, address to, uint256 amount) internal override {
        if (to == address(0)) {
            // prevents infinite loop when burning
            super._update(from, to, amount);
            return;
        }
        if (from == address(0)) {
            assert(to == POOL_MANAGER);
            // permissioned token is being deposited
            super._update(from, to, amount);
            return;
        } else if (from != POOL_MANAGER) {
            // if the pool manager is the sender, the permissioned token is automatically released, skip the checks
            revert InvalidTransfer(from, to);
        }
        super._update(from, to, amount);
        if (from == POOL_MANAGER) {
            _unwrap(to, amount);
        }
        // the pool manager must always be the only holder of the permissions adapter
        assert(balanceOf(POOL_MANAGER) == totalSupply());
    }

    function _unwrap(address account, uint256 amount) internal {
        _burn(account, amount);
        PERMISSIONED_TOKEN.transfer(account, amount);
    }

    function _getName(IERC20 permissionedToken) private view returns (string memory) {
        return string.concat("Uniswap v4 ", ERC20(address(permissionedToken)).name());
    }

    function _getSymbol(IERC20 permissionedToken) private view returns (string memory) {
        return string.concat("v4", ERC20(address(permissionedToken)).symbol());
    }

    function decimals() public view override returns (uint8) {
        return ERC20(address(PERMISSIONED_TOKEN)).decimals();
    }

    function owner() public view override(Ownable, IPermissionsAdapter) returns (address) {
        return super.owner();
    }
}
