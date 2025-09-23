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
    IPermissionsAdapter public permissionsAdapter;
    address public mockPoolManager;
    address public owner;

    function setUp() public override {
        super.setUp();
        mockPoolManager = makeAddr("mockPoolManager");
        owner = makeAddr("owner");
        bytes memory args = abi.encode(permissionedToken, mockPoolManager, owner, allowlistChecker);
        bytes memory initcode = abi.encodePacked(vm.getCode("PermissionsAdapter.sol:PermissionsAdapter"), args);
        assembly {
            sstore(permissionsAdapter.slot, create(0, add(initcode, 0x20), mload(initcode)))
        }
        permissionedToken.setTokenAllowlist(address(permissionsAdapter), true);
        vm.prank(owner);
        permissionsAdapter.updateAllowedWrapper(address(this), true);
    }

    function test_InitialState() public view {
        assertEq(IERC20Metadata(address(permissionsAdapter)).name(), "Uniswap v4 MockToken");
        assertEq(IERC20Metadata(address(permissionsAdapter)).symbol(), "v4MT");
        assertEq(IERC20Metadata(address(permissionsAdapter)).decimals(), permissionedToken.decimals());
        assertEq(permissionsAdapter.totalSupply(), 0);
        assertEq(permissionsAdapter.balanceOf(mockPoolManager), 0);
        assertEq(address(permissionsAdapter.allowListChecker()), address(allowlistChecker));
        assertEq(permissionsAdapter.POOL_MANAGER(), mockPoolManager);
        assertEq(address(permissionsAdapter.PERMISSIONED_TOKEN()), address(permissionedToken));
    }

    function testRevert_WhenNotOwner(address account) public {
        vm.assume(account != owner);
        vm.startPrank(account);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, account));
        permissionsAdapter.updateAllowedWrapper(account, true);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, account));
        permissionsAdapter.updateAllowListChecker(allowlistChecker);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, account));
        permissionsAdapter.updateSwappingEnabled(true);
        vm.stopPrank();
    }

    function testRevert_WhenNotAllowedWrapper(address wrapper) public {
        vm.assume(wrapper != address(this));
        assertFalse(permissionsAdapter.allowedWrappers(wrapper));
        vm.prank(wrapper);
        vm.expectRevert(abi.encodeWithSelector(IPermissionsAdapter.UnauthorizedWrapper.selector, wrapper));
        permissionsAdapter.wrapToPoolManager(100);
    }

    function testRevert_WhenInsufficientBalance(uint256 amount, uint256 transferAmount) public {
        vm.assume(amount != 0);
        transferAmount = bound(amount, 0, amount - 1);
        permissionedToken.mint(address(permissionsAdapter), transferAmount);
        vm.expectRevert(
            abi.encodeWithSelector(IPermissionsAdapter.InsufficientBalance.selector, amount, transferAmount)
        );
        permissionsAdapter.wrapToPoolManager(amount);
    }

    function test_WrapToPoolManager(uint256 amount, uint256 actualAmount) public {
        actualAmount = bound(amount, amount, type(uint256).max);
        permissionedToken.mint(address(permissionsAdapter), actualAmount);
        vm.expectEmit(true, true, true, true);
        emit IERC20.Transfer(address(0), mockPoolManager, amount);
        permissionsAdapter.wrapToPoolManager(amount);
        assertEq(permissionsAdapter.balanceOf(mockPoolManager), amount);
        assertEq(permissionedToken.balanceOf(mockPoolManager), actualAmount - amount);
    }

    function test_UpdateAllowedWrapper(address wrapper, bool allowed) public {
        vm.assume(wrapper != address(this));
        assertFalse(permissionsAdapter.allowedWrappers(wrapper));
        vm.prank(owner);
        vm.expectEmit(true, true, true, true);
        emit IPermissionsAdapter.AllowedWrapperUpdated(wrapper, allowed);
        permissionsAdapter.updateAllowedWrapper(wrapper, allowed);
        assertEq(permissionsAdapter.allowedWrappers(wrapper), allowed);
    }

    function testRevert_WhenNotSupportedInterfaceEOA(IAllowlistChecker newAllowListCheckerEOA) public {
        vm.assume(newAllowListCheckerEOA != allowlistChecker);
        vm.prank(owner);
        vm.expectRevert(); // expect revert without data
        permissionsAdapter.updateAllowListChecker(newAllowListCheckerEOA);
    }

    function testRevert_WhenNotSupportedInterfaceContract() public {
        IAllowlistChecker newAllowListCheckerContract = new ImproperAllowlistChecker();
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(IPermissionsAdapter.InvalidAllowListChecker.selector, newAllowListCheckerContract)
        );
        permissionsAdapter.updateAllowListChecker(newAllowListCheckerContract);
    }

    function test_UpdateAllowListChecker() public {
        IAllowlistChecker newAllowListChecker = new MockAllowlistChecker(permissionedToken);
        vm.prank(owner);
        vm.expectEmit(true, true, true, true);
        emit IPermissionsAdapter.AllowListCheckerUpdated(newAllowListChecker);
        permissionsAdapter.updateAllowListChecker(newAllowListChecker);
        assertEq(address(permissionsAdapter.allowListChecker()), address(newAllowListChecker));
    }

    function test_UpdateSwappingEnabled(bool enabled) public {
        vm.prank(owner);
        vm.expectEmit(true, true, true, true);
        emit IPermissionsAdapter.SwappingEnabledUpdated(enabled);
        permissionsAdapter.updateSwappingEnabled(enabled);
        assertEq(permissionsAdapter.swappingEnabled(), enabled);
    }

    function testRevert_WhenInvalidTransfer(address from, address to) public {
        vm.assume(from != address(0) && from != mockPoolManager);
        vm.assume(to != address(0) && to != mockPoolManager);
        vm.prank(from);
        vm.expectRevert(abi.encodeWithSelector(IPermissionsAdapter.InvalidTransfer.selector, from, to));
        permissionsAdapter.transfer(to, 0);
    }

    function test_UnwrapOnPoolManagerTransfer(uint256 mintAmount, uint256 transferAmount, address recipient) public {
        vm.assume(recipient != address(0) && recipient != mockPoolManager && recipient != address(permissionsAdapter));
        assertEq(permissionedToken.balanceOf(recipient), 0);
        permissionedToken.setTokenAllowlist(recipient, true);
        transferAmount = bound(transferAmount, 0, mintAmount);
        permissionedToken.mint(address(permissionsAdapter), mintAmount);
        permissionsAdapter.wrapToPoolManager(mintAmount);
        vm.prank(mockPoolManager);
        vm.expectEmit(true, true, true, true);
        emit IERC20.Transfer(mockPoolManager, recipient, transferAmount);
        vm.expectEmit(true, true, true, true);
        emit IERC20.Transfer(recipient, address(0), transferAmount);
        permissionsAdapter.transfer(recipient, transferAmount);
        assertEq(permissionsAdapter.balanceOf(mockPoolManager), mintAmount - transferAmount);
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
