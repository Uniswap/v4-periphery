// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {
    IPermissionsAdapter,
    IAllowlistChecker
} from "../../../src/hooks/permissionedPools/interfaces/IPermissionsAdapter.sol";
import {IERC20, IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {PermissionedPoolsBase, MockAllowlistChecker} from "./PermissionedPoolsBase.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {PermissionFlags, PermissionFlag} from "../../../src/hooks/permissionedPools/libraries/PermissionFlags.sol";

contract PermissionsAdapterTest is PermissionedPoolsBase {
    IPermissionsAdapter public pemissionsAdapter;
    address public mockPoolManager;
    address public owner;

    function setUp() public override {
        super.setUp();
        mockPoolManager = makeAddr("mockPoolManager");
        owner = makeAddr("owner");
        bytes memory args = abi.encode(permissionedToken, mockPoolManager, owner, allowlistChecker);
        bytes memory initcode = abi.encodePacked(vm.getCode("PermissionsAdapter.sol:PermissionsAdapter"), args);
        assembly {
            sstore(pemissionsAdapter.slot, create(0, add(initcode, 0x20), mload(initcode)))
        }
        permissionedToken.setTokenAllowlist(address(pemissionsAdapter), true);
        vm.prank(owner);
        pemissionsAdapter.updateAllowedWrapper(address(this), true);
    }

    function test_InitialState() public view {
        assertEq(IERC20Metadata(address(pemissionsAdapter)).name(), "Uniswap v4 MockToken");
        assertEq(IERC20Metadata(address(pemissionsAdapter)).symbol(), "v4MT");
        assertEq(IERC20Metadata(address(pemissionsAdapter)).decimals(), permissionedToken.decimals());
        assertEq(pemissionsAdapter.totalSupply(), 0);
        assertEq(pemissionsAdapter.balanceOf(mockPoolManager), 0);
        assertEq(address(pemissionsAdapter.allowListChecker()), address(allowlistChecker));
        assertEq(pemissionsAdapter.POOL_MANAGER(), mockPoolManager);
        assertEq(address(pemissionsAdapter.PERMISSIONED_TOKEN()), address(permissionedToken));
    }

    function testRevert_WhenNotOwner(address account) public {
        vm.assume(account != owner);
        vm.startPrank(account);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, account));
        pemissionsAdapter.updateAllowedWrapper(account, true);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, account));
        pemissionsAdapter.updateAllowListChecker(allowlistChecker);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, account));
        pemissionsAdapter.updateSwappingEnabled(true);
        vm.stopPrank();
    }

    function testRevert_WhenNotAllowedWrapper(address wrapper) public {
        vm.assume(wrapper != address(this));
        assertFalse(pemissionsAdapter.allowedWrappers(wrapper));
        vm.prank(wrapper);
        vm.expectRevert(abi.encodeWithSelector(IPermissionsAdapter.UnauthorizedWrapper.selector, wrapper));
        pemissionsAdapter.wrapToPoolManager(100);
    }

    function testRevert_WhenInsufficientBalance(uint256 amount, uint256 transferAmount) public {
        vm.assume(amount != 0);
        transferAmount = bound(amount, 0, amount - 1);
        permissionedToken.mint(address(pemissionsAdapter), transferAmount);
        vm.expectRevert(
            abi.encodeWithSelector(IPermissionsAdapter.InsufficientBalance.selector, amount, transferAmount)
        );
        pemissionsAdapter.wrapToPoolManager(amount);
    }

    function test_WrapToPoolManager(uint256 amount, uint256 actualAmount) public {
        actualAmount = bound(amount, amount, type(uint256).max);
        permissionedToken.mint(address(pemissionsAdapter), actualAmount);
        vm.expectEmit(true, true, true, true);
        emit IERC20.Transfer(address(0), mockPoolManager, amount);
        pemissionsAdapter.wrapToPoolManager(amount);
        assertEq(pemissionsAdapter.balanceOf(mockPoolManager), amount);
        assertEq(permissionedToken.balanceOf(mockPoolManager), actualAmount - amount);
    }

    function test_UpdateAllowedWrapper(address wrapper, bool allowed) public {
        vm.assume(wrapper != address(this));
        assertFalse(pemissionsAdapter.allowedWrappers(wrapper));
        vm.prank(owner);
        vm.expectEmit(true, true, true, true);
        emit IPermissionsAdapter.AllowedWrapperUpdated(wrapper, allowed);
        pemissionsAdapter.updateAllowedWrapper(wrapper, allowed);
        assertEq(pemissionsAdapter.allowedWrappers(wrapper), allowed);
    }

    function testRevert_WhenNotSupportedInterfaceEOA(IAllowlistChecker newAllowListCheckerEOA) public {
        vm.assume(newAllowListCheckerEOA != allowlistChecker);
        vm.prank(owner);
        vm.expectRevert(); // expect revert without data
        pemissionsAdapter.updateAllowListChecker(newAllowListCheckerEOA);
    }

    function testRevert_WhenNotSupportedInterfaceContract() public {
        IAllowlistChecker newAllowListCheckerContract = new ImproperAllowlistChecker();
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(IPermissionsAdapter.InvalidAllowListChecker.selector, newAllowListCheckerContract)
        );
        pemissionsAdapter.updateAllowListChecker(newAllowListCheckerContract);
    }

    function test_UpdateAllowListChecker() public {
        IAllowlistChecker newAllowListChecker = new MockAllowlistChecker(permissionedToken);
        vm.prank(owner);
        vm.expectEmit(true, true, true, true);
        emit IPermissionsAdapter.AllowListCheckerUpdated(newAllowListChecker);
        pemissionsAdapter.updateAllowListChecker(newAllowListChecker);
        assertEq(address(pemissionsAdapter.allowListChecker()), address(newAllowListChecker));
    }

    function test_UpdateSwappingEnabled(bool enabled) public {
        vm.prank(owner);
        vm.expectEmit(true, true, true, true);
        emit IPermissionsAdapter.SwappingEnabledUpdated(enabled);
        pemissionsAdapter.updateSwappingEnabled(enabled);
        assertEq(pemissionsAdapter.swappingEnabled(), enabled);
    }

    function testRevert_WhenInvalidTransfer(address from, address to) public {
        vm.assume(from != address(0) && from != mockPoolManager);
        vm.assume(to != address(0) && to != mockPoolManager);
        vm.prank(from);
        vm.expectRevert(abi.encodeWithSelector(IPermissionsAdapter.InvalidTransfer.selector, from, to));
        pemissionsAdapter.transfer(to, 0);
    }

    function test_UnwrapOnPoolManagerTransfer(uint256 mintAmount, uint256 transferAmount, address recipient) public {
        vm.assume(recipient != address(0) && recipient != mockPoolManager && recipient != address(pemissionsAdapter));
        assertEq(permissionedToken.balanceOf(recipient), 0);
        permissionedToken.setTokenAllowlist(recipient, true);
        transferAmount = bound(transferAmount, 0, mintAmount);
        permissionedToken.mint(address(pemissionsAdapter), mintAmount);
        pemissionsAdapter.wrapToPoolManager(mintAmount);
        vm.prank(mockPoolManager);
        vm.expectEmit(true, true, true, true);
        emit IERC20.Transfer(mockPoolManager, recipient, transferAmount);
        vm.expectEmit(true, true, true, true);
        emit IERC20.Transfer(recipient, address(0), transferAmount);
        pemissionsAdapter.transfer(recipient, transferAmount);
        assertEq(pemissionsAdapter.balanceOf(mockPoolManager), mintAmount - transferAmount);
        assertEq(permissionedToken.balanceOf(recipient), transferAmount);
    }
}

contract ImproperAllowlistChecker is IAllowlistChecker {
    function checkAllowlist(address) public pure returns (PermissionFlag) {
        return PermissionFlags.ALL_ALLOWED;
    }

    function supportsInterface(bytes4) external pure returns (bool) {
        return false;
    }
}
