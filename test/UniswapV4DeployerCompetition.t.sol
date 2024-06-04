// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Owned} from "solmate/auth/Owned.sol";
import {Test, console2} from "forge-std/Test.sol";
import {PoolManager} from "v4-core/PoolManager.sol";
import {UniswapV4DeployerCompetition} from "../contracts/UniswapV4DeployerCompetition.sol";

contract UniswapV4DeployerCompetitionTest is Test {
    UniswapV4DeployerCompetition deployer;
    bytes32 initCodeHash;
    address v4Owner;
    address winner;
    uint256 constant controllerGasLimit = 10000;

    function setUp() public {
        v4Owner = makeAddr("V4Owner");
        winner = makeAddr("Winner");
        initCodeHash = keccak256(abi.encodePacked(type(PoolManager).creationCode, controllerGasLimit));
        deployer = new UniswapV4DeployerCompetition{value: 1 ether}(initCodeHash, v4Owner);
    }

    function testUpdateBestAddress(bytes32 salt) public {
        assertEq(deployer.bestAddress(), address(0));
        assertEq(deployer.bestAddressSender(), address(0));
        assertEq(deployer.bestAddressSalt(), bytes32(0));

        vm.prank(winner);
        deployer.updateBestAddress(salt);
        assertEq(address(deployer).balance, 1 ether);
        assertFalse(deployer.bestAddress() == address(0));
        assertEq(deployer.bestAddressSender(), winner);
        assertEq(deployer.bestAddressSalt(), salt);
        address v4Core = deployer.bestAddress();

        assertEq(v4Core.code.length, 0);
        vm.warp(deployer.competitionDeadline() + 1);
        vm.prank(winner);
        deployer.deploy(abi.encodePacked(type(PoolManager).creationCode, controllerGasLimit));
        assertFalse(v4Core.code.length == 0);
        assertEq(Owned(v4Core).owner(), v4Owner);
        assertEq(PoolManager(v4Core).MAX_TICK_SPACING(), type(int16).max);
        assertEq(address(deployer).balance, 0 ether);
        assertEq(winner.balance, 1 ether);
    }

    function testCompetitionOver(bytes32 salt) public {
        vm.warp(deployer.competitionDeadline() + 1);
        vm.expectRevert(UniswapV4DeployerCompetition.CompetitionOver.selector);
        deployer.updateBestAddress(salt);
    }

    function testUpdateBestAddressOpen(bytes32 salt) public {
        vm.prank(winner);
        deployer.updateBestAddress(salt);
        address v4Core = deployer.bestAddress();

        vm.warp(deployer.competitionDeadline() + 1.1 days);
        deployer.deploy(abi.encodePacked(type(PoolManager).creationCode, controllerGasLimit));
        assertFalse(v4Core.code.length == 0);
        assertEq(Owned(v4Core).owner(), v4Owner);
        assertEq(PoolManager(v4Core).MAX_TICK_SPACING(), type(int16).max);
    }

    function testCompetitionNotOver(bytes32 salt, uint256 timestamp) public {
        vm.assume(timestamp < deployer.competitionDeadline());
        vm.prank(winner);
        deployer.updateBestAddress(salt);
        vm.warp(timestamp);
        vm.expectRevert(UniswapV4DeployerCompetition.CompetitionNotOver.selector);
        deployer.deploy(abi.encodePacked(type(PoolManager).creationCode, controllerGasLimit));
    }

    function testInvalidBytecode(bytes32 salt) public {
        vm.prank(winner);
        deployer.updateBestAddress(salt);
        vm.expectRevert(UniswapV4DeployerCompetition.InvalidBytecode.selector);
        deployer.deploy(abi.encodePacked(type(PoolManager).creationCode, controllerGasLimit + 1));
    }

    function testEqualSaltNotChanged(bytes32 salt) public {
        vm.prank(winner);
        deployer.updateBestAddress(salt);
        assertEq(deployer.bestAddressSender(), winner);
        assertEq(deployer.bestAddressSalt(), salt);

        vm.prank(address(1));
        vm.expectRevert(UniswapV4DeployerCompetition.WorseAddress.selector);
        deployer.updateBestAddress(salt);
    }

    function testUpdateNotEqual() public {
        bytes32 salt1 = keccak256(abi.encodePacked(uint256(1)));
        bytes32 salt2 = keccak256(abi.encodePacked(uint256(2)));
        vm.prank(winner);
        deployer.updateBestAddress(salt1);
        vm.prank(winner);
        deployer.updateBestAddress(salt2);
        assertFalse(deployer.bestAddress() == address(0));
        assertEq(deployer.bestAddressSender(), winner);
        assertEq(deployer.bestAddressSalt(), salt2);
    }
}
