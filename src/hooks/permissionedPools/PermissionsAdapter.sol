// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {ERC165Checker} from "@openzeppelin/contracts/utils/introspection/ERC165Checker.sol";
import {ERC20 as SafeERC20} from "solmate/src/tokens/ERC20.sol";
import {SafeTransferLib} from "solmate/src/utils/SafeTransferLib.sol";
import {IPermissionsAdapter} from "./interfaces/IPermissionsAdapter.sol";
import {IAllowlistChecker} from "./interfaces/IAllowlistChecker.sol";
import {PermissionFlag} from "./libraries/PermissionFlags.sol";

contract PermissionsAdapter is ERC20, Ownable2Step, IPermissionsAdapter {
    using SafeTransferLib for SafeERC20;

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
    function depositForVerification(uint256 amount) external {
        SafeERC20(address(PERMISSIONED_TOKEN)).safeTransferFrom(msg.sender, address(this), amount);
        emit VerificationDeposit(msg.sender, amount);
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
        return ((allowListChecker.checkAllowlist(account, address(PERMISSIONED_TOKEN))) & (permission)) == (permission);
    }

    function _updateAllowListChecker(IAllowlistChecker newAllowListChecker) internal {
        if (!ERC165Checker.supportsInterface(address(newAllowListChecker), type(IAllowlistChecker).interfaceId)) {
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
        // reject self-transfer: would unwrap raw underlying into PoolManager
        if (to == POOL_MANAGER) revert InvalidTransfer(from, to);
        super._update(from, to, amount);
        _unwrap(to, amount);
        // the pool manager must always be the only holder of the permissions adapter
        assert(balanceOf(POOL_MANAGER) == totalSupply());
    }

    function _unwrap(address account, uint256 amount) internal {
        _burn(account, amount);
        SafeERC20(address(PERMISSIONED_TOKEN)).safeTransfer(account, amount);
    }

    /// @dev Low-level staticcall + ABI-layout validation. try/catch doesn't catch return-data decode failures,
    /// so tokens returning bytes32 (MKR-style) or other non-string shapes must be checked explicitly.
    function _readString(address token, bytes4 selector, string memory fallback_) private view returns (string memory) {
        (bool ok, bytes memory data) = token.staticcall(abi.encodeWithSelector(selector));
        if (!ok || data.length < 64) return fallback_;
        uint256 offset;
        uint256 length;
        assembly ("memory-safe") {
            offset := mload(add(data, 0x20))
            length := mload(add(data, 0x40))
        }
        if (offset != 0x20 || length == 0 || length > data.length - 64) return fallback_;
        return abi.decode(data, (string));
    }

    function _getName(IERC20 permissionedToken) private view returns (string memory) {
        return string.concat(
            "Uniswap v4 ", _readString(address(permissionedToken), IERC20Metadata.name.selector, "Permissioned Token")
        );
    }

    function _getSymbol(IERC20 permissionedToken) private view returns (string memory) {
        return string.concat("v4", _readString(address(permissionedToken), IERC20Metadata.symbol.selector, "PT"));
    }

    function decimals() public view override returns (uint8) {
        (bool ok, bytes memory data) =
            address(PERMISSIONED_TOKEN).staticcall(abi.encodeWithSelector(IERC20Metadata.decimals.selector));
        if (!ok || data.length < 32) return 18;
        uint256 value = abi.decode(data, (uint256));
        return value > type(uint8).max ? 18 : uint8(value);
    }

    function owner() public view override(Ownable, IPermissionsAdapter) returns (address) {
        return super.owner();
    }
}
