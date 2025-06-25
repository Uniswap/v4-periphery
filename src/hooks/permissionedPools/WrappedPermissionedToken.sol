// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {IWrappedPermissionedToken} from "./interfaces/IWrappedPermissionedToken.sol";
import {IAllowlistChecker} from "./interfaces/IAllowlistChecker.sol";

contract WrappedPermissionedToken is ERC20, Ownable2Step, IWrappedPermissionedToken {
    /// @inheritdoc IWrappedPermissionedToken
    address public immutable POOL_MANAGER;
    /// @inheritdoc IWrappedPermissionedToken
    IERC20 public immutable PERMISSIONED_TOKEN;

    /// @inheritdoc IWrappedPermissionedToken
    IAllowlistChecker public allowListChecker;

    /// @inheritdoc IWrappedPermissionedToken
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

    /// @inheritdoc IWrappedPermissionedToken
    function wrapToPoolManager(uint256 amount) external {
        if (!allowedWrappers[msg.sender]) revert UnauthorizedWrapper(msg.sender);
        uint256 availableBalance = PERMISSIONED_TOKEN.balanceOf(address(this)) - totalSupply();
        if (amount > availableBalance) revert InsufficientBalance(amount, availableBalance);
        _mint(POOL_MANAGER, amount);
    }

    /// @inheritdoc IWrappedPermissionedToken
    function updateAllowListChecker(IAllowlistChecker newAllowListChecker) external onlyOwner {
        _updateAllowListChecker(newAllowListChecker);
    }

    /// @inheritdoc IWrappedPermissionedToken
    function updateAllowedWrapper(address wrapper, bool allowed) external onlyOwner {
        _updateAllowedWrapper(wrapper, allowed);
    }

    /// @inheritdoc IWrappedPermissionedToken
    function isAllowed(address account) public view returns (bool) {
        return allowListChecker.checkAllowList(account);
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

    /// @dev Overrides the ERC20._update function to add the following checks and logic:
    /// - Before `settle` is called on the pool manager, the token is wrapped and minted to the pool manager
    /// - When `take` is called on the pool manager, the token is automatically unwrapped when the pool manager transfers the token to the recipient
    /// - Enforces that the pool manager is the only holder of the wrapped token
    function _update(address from, address to, uint256 amount) internal override {
        if (to == address(0)) {
            // prevents infinite loop when burning
            super._update(from, to, amount);
            return;
        }
        if (from == address(0)) {
            assert(to == POOL_MANAGER);
            // token is being wrapped
            super._update(from, to, amount);
            return;
        } else if (from != POOL_MANAGER) {
            // if the pool manager is the sender, the token is automatically unwrapped, skip the checks
            revert InvalidTransfer(from, to);
        }
        super._update(from, to, amount);
        if (from == POOL_MANAGER) {
            _unwrap(to, amount);
        }
        // the pool manager must always be the only holder of the wrapped token
        assert(balanceOf(POOL_MANAGER) == totalSupply());
    }

    function _unwrap(address account, uint256 amount) internal {
        _burn(account, amount);
        PERMISSIONED_TOKEN.transfer(account, amount);
    }

    function _getName(IERC20 permissionedToken) private view returns (string memory) {
        return string.concat("Uniswap v4 Wrapped ", ERC20(address(permissionedToken)).name());
    }

    function _getSymbol(IERC20 permissionedToken) private view returns (string memory) {
        return string.concat("uw", ERC20(address(permissionedToken)).symbol());
    }
}
