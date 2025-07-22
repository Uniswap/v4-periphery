// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {
    IWrappedPermissionedToken,
    IAllowlistChecker
} from "../../../src/hooks/permissionedPools/interfaces/IWrappedPermissionedToken.sol";
import {IERC20, IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {PermissionedPoolsBase, MockAllowlistChecker} from "./PermissionedPoolsBase.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {PermissionFlags, PermissionFlag} from "../../../src/hooks/permissionedPools/libraries/PermissionFlags.sol";

contract WrappedPermissionedTokenTest is PermissionedPoolsBase {
    IWrappedPermissionedToken public wrappedPermissionedToken;
    address public mockPoolManager;
    address public owner;

    function setUp() public override {
        super.setUp();
        mockPoolManager = makeAddr("mockPoolManager");
        owner = makeAddr("owner");
        bytes memory args = abi.encode(permissionedToken, mockPoolManager, owner, allowlistChecker);
        bytes memory initcode =
            abi.encodePacked(vm.getCode("WrappedPermissionedToken.sol:WrappedPermissionedToken"), args);
        assembly {
            sstore(wrappedPermissionedToken.slot, create(0, add(initcode, 0x20), mload(initcode)))
        }
        permissionedToken.setTokenAllowlist(address(wrappedPermissionedToken), true);
        vm.prank(owner);
        wrappedPermissionedToken.updateAllowedWrapper(address(this), true);
    }

    function test_InitialState() public view {
        assertEq(IERC20Metadata(address(wrappedPermissionedToken)).name(), "Uniswap v4 Wrapped MockToken");
        assertEq(IERC20Metadata(address(wrappedPermissionedToken)).symbol(), "uwMT");
        assertEq(IERC20Metadata(address(wrappedPermissionedToken)).decimals(), permissionedToken.decimals());
        assertEq(wrappedPermissionedToken.totalSupply(), 0);
        assertEq(wrappedPermissionedToken.balanceOf(mockPoolManager), 0);
        assertEq(address(wrappedPermissionedToken.allowListChecker()), address(allowlistChecker));
        assertEq(wrappedPermissionedToken.POOL_MANAGER(), mockPoolManager);
        assertEq(address(wrappedPermissionedToken.PERMISSIONED_TOKEN()), address(permissionedToken));
    }

    function testRevert_WhenNotOwner(address account) public {
        vm.assume(account != owner);
        vm.startPrank(account);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, account));
        wrappedPermissionedToken.updateAllowedWrapper(account, true);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, account));
        wrappedPermissionedToken.updateAllowListChecker(allowlistChecker);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, account));
        wrappedPermissionedToken.updateSwappingEnabled(true);
        vm.stopPrank();
    }

    function testRevert_WhenNotAllowedWrapper(address wrapper) public {
        vm.assume(wrapper != address(this));
        assertFalse(wrappedPermissionedToken.allowedWrappers(wrapper));
        vm.prank(wrapper);
        vm.expectRevert(abi.encodeWithSelector(IWrappedPermissionedToken.UnauthorizedWrapper.selector, wrapper));
        wrappedPermissionedToken.wrapToPoolManager(100);
    }

    function testRevert_WhenInsufficientBalance(uint256 amount, uint256 transferAmount) public {
        vm.assume(amount != 0);
        transferAmount = bound(amount, 0, amount - 1);
        permissionedToken.mint(address(wrappedPermissionedToken), transferAmount);
        vm.expectRevert(
            abi.encodeWithSelector(IWrappedPermissionedToken.InsufficientBalance.selector, amount, transferAmount)
        );
        wrappedPermissionedToken.wrapToPoolManager(amount);
    }

    function test_WrapToPoolManager(uint256 amount, uint256 actualAmount) public {
        actualAmount = bound(amount, amount, type(uint256).max);
        permissionedToken.mint(address(wrappedPermissionedToken), actualAmount);
        vm.expectEmit(true, true, true, true);
        emit IERC20.Transfer(address(0), mockPoolManager, amount);
        wrappedPermissionedToken.wrapToPoolManager(amount);
        assertEq(wrappedPermissionedToken.balanceOf(mockPoolManager), amount);
        assertEq(permissionedToken.balanceOf(mockPoolManager), actualAmount - amount);
    }

    function test_UpdateAllowedWrapper(address wrapper, bool allowed) public {
        vm.assume(wrapper != address(this));
        assertFalse(wrappedPermissionedToken.allowedWrappers(wrapper));
        vm.prank(owner);
        vm.expectEmit(true, true, true, true);
        emit IWrappedPermissionedToken.AllowedWrapperUpdated(wrapper, allowed);
        wrappedPermissionedToken.updateAllowedWrapper(wrapper, allowed);
        assertEq(wrappedPermissionedToken.allowedWrappers(wrapper), allowed);
    }

    function testRevert_WhenNotSupportedInterfaceEOA(IAllowlistChecker newAllowListCheckerEOA) public {
        vm.assume(newAllowListCheckerEOA != allowlistChecker);
        vm.prank(owner);
        vm.expectRevert(); // expect revert without data
        wrappedPermissionedToken.updateAllowListChecker(newAllowListCheckerEOA);
    }

    function testRevert_WhenNotSupportedInterfaceContract() public {
        IAllowlistChecker newAllowListCheckerContract = new ImproperAllowlistChecker();
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(
                IWrappedPermissionedToken.InvalidAllowListChecker.selector, newAllowListCheckerContract
            )
        );
        wrappedPermissionedToken.updateAllowListChecker(newAllowListCheckerContract);
    }

    function test_UpdateAllowListChecker() public {
        IAllowlistChecker newAllowListChecker = new MockAllowlistChecker(permissionedToken);
        vm.prank(owner);
        vm.expectEmit(true, true, true, true);
        emit IWrappedPermissionedToken.AllowListCheckerUpdated(newAllowListChecker);
        wrappedPermissionedToken.updateAllowListChecker(newAllowListChecker);
        assertEq(address(wrappedPermissionedToken.allowListChecker()), address(newAllowListChecker));
    }

    function test_UpdateSwappingEnabled(bool enabled) public {
        vm.prank(owner);
        vm.expectEmit(true, true, true, true);
        emit IWrappedPermissionedToken.SwappingEnabledUpdated(enabled);
        wrappedPermissionedToken.updateSwappingEnabled(enabled);
        assertEq(wrappedPermissionedToken.swappingEnabled(), enabled);
    }

    function testRevert_WhenInvalidTransfer(address from, address to) public {
        vm.assume(from != address(0) && from != mockPoolManager);
        vm.assume(to != address(0) && to != mockPoolManager);
        vm.prank(from);
        vm.expectRevert(abi.encodeWithSelector(IWrappedPermissionedToken.InvalidTransfer.selector, from, to));
        wrappedPermissionedToken.transfer(to, 0);
    }

    function test_UnwrapOnPoolManagerTransfer(uint256 mintAmount, uint256 transferAmount, address recipient) public {
        vm.assume(
            recipient != address(0) && recipient != mockPoolManager && recipient != address(wrappedPermissionedToken)
        );
        assertEq(permissionedToken.balanceOf(recipient), 0);
        permissionedToken.setTokenAllowlist(recipient, true);
        transferAmount = bound(transferAmount, 0, mintAmount);
        permissionedToken.mint(address(wrappedPermissionedToken), mintAmount);
        wrappedPermissionedToken.wrapToPoolManager(mintAmount);
        vm.prank(mockPoolManager);
        vm.expectEmit(true, true, true, true);
        emit IERC20.Transfer(mockPoolManager, recipient, transferAmount);
        vm.expectEmit(true, true, true, true);
        emit IERC20.Transfer(recipient, address(0), transferAmount);
        wrappedPermissionedToken.transfer(recipient, transferAmount);
        assertEq(wrappedPermissionedToken.balanceOf(mockPoolManager), mintAmount - transferAmount);
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
