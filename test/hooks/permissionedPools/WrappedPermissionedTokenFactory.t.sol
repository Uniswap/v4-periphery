// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {
    IWrappedPermissionedToken,
    IAllowlistChecker
} from "../../../src/hooks/permissionedPools/interfaces/IWrappedPermissionedToken.sol";
import {IWrappedPermissionedTokenFactory} from
    "../../../src/hooks/permissionedPools/interfaces/IWrappedPermissionedTokenFactory.sol";
import {IERC20, IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {PermissionedPoolsBase, MockAllowlistChecker} from "./PermissionedPoolsBase.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {PermissionFlags} from "../../../src/hooks/permissionedPools/libraries/PermissionFlags.sol";

contract WrappedPermissionedTokenFactoryTest is PermissionedPoolsBase {
    IWrappedPermissionedTokenFactory public wrappedPermissionedTokenFactory;
    address public mockPoolManager;

    function setUp() public override {
        super.setUp();
        mockPoolManager = makeAddr("mockPoolManager");
        bytes memory args = abi.encode(mockPoolManager);
        bytes memory initcode =
            abi.encodePacked(vm.getCode("WrappedPermissionedTokenFactory.sol:WrappedPermissionedTokenFactory"), args);
        assembly {
            sstore(wrappedPermissionedTokenFactory.slot, create(0, add(initcode, 0x20), mload(initcode)))
        }
    }

    function test_InitialState() public view {
        assertEq(wrappedPermissionedTokenFactory.POOL_MANAGER(), mockPoolManager);
    }

    function test_CreateWrappedPermissionedToken(address initialOwner) public {
        vm.assume(initialOwner != address(0));
        address expectedWrappedPermissionedToken = vm.computeCreateAddress(address(wrappedPermissionedTokenFactory), 1);
        vm.expectEmit(true, true, true, true);
        emit IWrappedPermissionedTokenFactory.WrappedPermissionedTokenCreated(
            expectedWrappedPermissionedToken, address(permissionedToken)
        );
        address wrappedPermissionedToken = wrappedPermissionedTokenFactory.createWrappedPermissionedToken(
            permissionedToken, initialOwner, allowlistChecker
        );
        assertEq(wrappedPermissionedToken, expectedWrappedPermissionedToken);
        assertEq(
            wrappedPermissionedTokenFactory.permissionedTokenOf(wrappedPermissionedToken), address(permissionedToken)
        );
        assertEq(wrappedPermissionedTokenFactory.verifiedPermissionedTokenOf(wrappedPermissionedToken), address(0));
    }

    function testRevert_WhenWrappedTokenNotDeployed(address wrappedToken) public {
        vm.expectRevert(
            abi.encodeWithSelector(IWrappedPermissionedTokenFactory.WrappedTokenNotFound.selector, wrappedToken)
        );
        wrappedPermissionedTokenFactory.verifyWrappedToken(wrappedToken);
    }

    function testRevert_WhenWrappedTokenNotVerified() public {
        address wrappedPermissionedToken = wrappedPermissionedTokenFactory.createWrappedPermissionedToken(
            permissionedToken, makeAddr("initialOwner"), allowlistChecker
        );
        vm.expectRevert(
            abi.encodeWithSelector(
                IWrappedPermissionedTokenFactory.WrappedTokenNotVerified.selector, wrappedPermissionedToken
            )
        );
        wrappedPermissionedTokenFactory.verifyWrappedToken(wrappedPermissionedToken);
    }

    function test_VerifyWrappedToken() public {
        address wrappedPermissionedToken = wrappedPermissionedTokenFactory.createWrappedPermissionedToken(
            permissionedToken, makeAddr("initialOwner"), allowlistChecker
        );
        permissionedToken.setAllowlist(wrappedPermissionedToken, PermissionFlags.ALL_ALLOWED);
        permissionedToken.mint(wrappedPermissionedToken, 1);
        vm.expectEmit(true, true, true, true);
        emit IWrappedPermissionedTokenFactory.WrappedTokenVerified(wrappedPermissionedToken, address(permissionedToken));
        wrappedPermissionedTokenFactory.verifyWrappedToken(wrappedPermissionedToken);
        assertEq(
            wrappedPermissionedTokenFactory.verifiedPermissionedTokenOf(wrappedPermissionedToken),
            address(permissionedToken)
        );
    }

    function testRevert_WhenWrappedTokenAlreadyVerified() public {
        address wrappedPermissionedToken = wrappedPermissionedTokenFactory.createWrappedPermissionedToken(
            permissionedToken, makeAddr("initialOwner"), allowlistChecker
        );
        permissionedToken.setAllowlist(wrappedPermissionedToken, PermissionFlags.ALL_ALLOWED);
        permissionedToken.mint(wrappedPermissionedToken, 1);
        wrappedPermissionedTokenFactory.verifyWrappedToken(wrappedPermissionedToken);
        vm.expectRevert(
            abi.encodeWithSelector(
                IWrappedPermissionedTokenFactory.WrappedTokenAlreadyVerified.selector, wrappedPermissionedToken
            )
        );
        wrappedPermissionedTokenFactory.verifyWrappedToken(wrappedPermissionedToken);
    }
}
