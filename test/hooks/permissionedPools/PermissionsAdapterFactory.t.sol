// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {
    IPermissionsAdapter,
    IAllowlistChecker
} from "../../../src/hooks/permissionedPools/interfaces/IPermissionsAdapter.sol";
import {IPermissionsAdapterFactory} from
    "../../../src/hooks/permissionedPools/interfaces/IPermissionsAdapterFactory.sol";
import {IERC20, IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {PermissionedPoolsBase, MockAllowlistChecker} from "./PermissionedPoolsBase.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {PermissionFlags} from "../../../src/hooks/permissionedPools/libraries/PermissionFlags.sol";

contract PermissionsAdapterFactoryTest is PermissionedPoolsBase {
    IPermissionsAdapterFactory public permissionsAdapterFactory;
    address public mockPoolManager;

    function setUp() public override {
        super.setUp();
        mockPoolManager = makeAddr("mockPoolManager");
        bytes memory args = abi.encode(mockPoolManager);
        bytes memory initcode =
            abi.encodePacked(vm.getCode("PermissionsAdapterFactory.sol:PermissionsAdapterFactory"), args);
        assembly {
            sstore(permissionsAdapterFactory.slot, create(0, add(initcode, 0x20), mload(initcode)))
        }
    }

    function test_InitialState() public view {
        assertEq(permissionsAdapterFactory.POOL_MANAGER(), mockPoolManager);
    }

    function test_CreatePermissionsAdapter(address initialOwner) public {
        vm.assume(initialOwner != address(0));
        address expectedPermissionsAdapter = vm.computeCreateAddress(address(permissionsAdapterFactory), 1);
        vm.expectEmit(true, true, true, true);
        emit IPermissionsAdapterFactory.PermissionsAdapterCreated(
            expectedPermissionsAdapter, address(permissionedToken)
        );
        address pemissionsAdapter =
            permissionsAdapterFactory.createPermissionsAdapter(permissionedToken, initialOwner, allowlistChecker);
        assertEq(pemissionsAdapter, expectedPermissionsAdapter);
        assertEq(permissionsAdapterFactory.permissionsAdapterOf(pemissionsAdapter), address(permissionedToken));
        assertEq(permissionsAdapterFactory.verifiedPermissionsAdapterOf(pemissionsAdapter), address(0));
    }

    function testRevert_WhenPemissionsAdapterNotDeployed(address pemissionsAdapter) public {
        vm.expectRevert(
            abi.encodeWithSelector(IPermissionsAdapterFactory.PemissionsAdapterNotFound.selector, pemissionsAdapter)
        );
        permissionsAdapterFactory.verifyPermissionsAdapter(pemissionsAdapter);
    }

    function testRevert_WhenPemissionsAdapterNotVerified() public {
        address pemissionsAdapter = permissionsAdapterFactory.createPermissionsAdapter(
            permissionedToken, makeAddr("initialOwner"), allowlistChecker
        );
        vm.expectRevert(
            abi.encodeWithSelector(IPermissionsAdapterFactory.PemissionsAdapterNotVerified.selector, pemissionsAdapter)
        );
        permissionsAdapterFactory.verifyPermissionsAdapter(pemissionsAdapter);
    }

    function test_VerifyPemissionsAdapter() public {
        address pemissionsAdapter = permissionsAdapterFactory.createPermissionsAdapter(
            permissionedToken, makeAddr("initialOwner"), allowlistChecker
        );
        permissionedToken.setAllowlist(pemissionsAdapter, PermissionFlags.ALL_ALLOWED);
        permissionedToken.mint(pemissionsAdapter, 1);
        vm.expectEmit(true, true, true, true);
        emit IPermissionsAdapterFactory.PemissionsAdapterVerified(pemissionsAdapter, address(permissionedToken));
        permissionsAdapterFactory.verifyPermissionsAdapter(pemissionsAdapter);
        assertEq(permissionsAdapterFactory.verifiedPermissionsAdapterOf(pemissionsAdapter), address(permissionedToken));
    }

    function testRevert_WhenPemissionsAdapterAlreadyVerified() public {
        address pemissionsAdapter = permissionsAdapterFactory.createPermissionsAdapter(
            permissionedToken, makeAddr("initialOwner"), allowlistChecker
        );
        permissionedToken.setAllowlist(pemissionsAdapter, PermissionFlags.ALL_ALLOWED);
        permissionedToken.mint(pemissionsAdapter, 1);
        permissionsAdapterFactory.verifyPermissionsAdapter(pemissionsAdapter);
        vm.expectRevert(
            abi.encodeWithSelector(
                IPermissionsAdapterFactory.PemissionsAdapterAlreadyVerified.selector, pemissionsAdapter
            )
        );
        permissionsAdapterFactory.verifyPermissionsAdapter(pemissionsAdapter);
    }
}
