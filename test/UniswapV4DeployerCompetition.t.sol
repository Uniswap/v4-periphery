// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {Owned} from "solmate/src/auth/Owned.sol";
import {Test} from "forge-std/Test.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {UniswapV4DeployerCompetition} from "../src/UniswapV4DeployerCompetition.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {VanityAddressLib} from "../src/libraries/VanityAddressLib.sol";
import {Create2} from "@openzeppelin/contracts/utils/Create2.sol";
import {IUniswapV4DeployerCompetition} from "../src/interfaces/IUniswapV4DeployerCompetition.sol";

contract UniswapV4DeployerCompetitionTest is Test {
    using VanityAddressLib for address;

    UniswapV4DeployerCompetition competition;
    bytes32 initCodeHash;
    address deployer;
    address v4Owner;
    address winner;
    address defaultAddress;
    uint256 competitionDeadline;
    uint256 exclusiveDeployLength = 1 days;

    bytes32 mask20bytes = bytes32(uint256(type(uint96).max));

    function setUp() public {
        competitionDeadline = block.timestamp + 7 days;
        v4Owner = makeAddr("V4Owner");
        winner = makeAddr("Winner");
        deployer = makeAddr("Deployer");
        vm.prank(deployer);
        initCodeHash = keccak256(abi.encodePacked(type(PoolManager).creationCode, uint256(uint160(v4Owner))));
        competition =
            new UniswapV4DeployerCompetition(initCodeHash, competitionDeadline, deployer, exclusiveDeployLength);
        defaultAddress = Create2.computeAddress(bytes32(0), initCodeHash, address(competition));
    }

    function test_defaultSalt_deploy_succeeds() public {
        assertEq(competition.bestAddressSubmitter(), address(0));
        assertEq(competition.bestAddressSalt(), bytes32(0));
        assertEq(competition.bestAddress(), defaultAddress);

        assertEq(defaultAddress.code.length, 0);
        vm.warp(competition.competitionDeadline() + 1);
        vm.prank(deployer);
        competition.deploy(abi.encodePacked(type(PoolManager).creationCode, uint256(uint160(v4Owner))));
        assertFalse(defaultAddress.code.length == 0);
        assertEq(Owned(defaultAddress).owner(), v4Owner);
    }

    function test_updateBestAddress_succeeds(bytes32 salt) public {
        salt = (salt & mask20bytes) | bytes32(bytes20(winner));

        assertEq(competition.bestAddressSubmitter(), address(0));
        assertEq(competition.bestAddressSalt(), bytes32(0));
        assertEq(competition.bestAddress(), defaultAddress);

        address newAddress = Create2.computeAddress(salt, initCodeHash, address(competition));
        vm.assume(newAddress.betterThan(defaultAddress));

        vm.prank(winner);
        vm.expectEmit(true, true, true, false, address(competition));
        emit IUniswapV4DeployerCompetition.NewAddressFound(newAddress, winner, VanityAddressLib.score(newAddress));
        competition.updateBestAddress(salt);
        assertFalse(competition.bestAddress() == address(0), "best address not set");
        assertEq(competition.bestAddress(), newAddress, "wrong address set");
        assertEq(competition.bestAddressSubmitter(), winner, "wrong submitter set");
        assertEq(competition.bestAddressSalt(), salt, "incorrect salt set");
        address v4Core = competition.bestAddress();

        assertEq(v4Core.code.length, 0);
        vm.warp(competition.competitionDeadline() + 1);
        vm.prank(deployer);
        competition.deploy(abi.encodePacked(type(PoolManager).creationCode, uint256(uint160(v4Owner))));
        assertFalse(v4Core.code.length == 0);
        assertEq(Owned(v4Core).owner(), v4Owner);
        assertEq(address(competition).balance, 0 ether);
    }

    function test_updateBestAddress_reverts_CompetitionOver(bytes32 salt) public {
        vm.warp(competition.competitionDeadline() + 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                IUniswapV4DeployerCompetition.CompetitionOver.selector,
                block.timestamp,
                competition.competitionDeadline()
            )
        );
        competition.updateBestAddress(salt);
    }

    function test_updateBestAddress_reverts_InvalidSigner(bytes32 salt) public {
        vm.assume(bytes20(salt) != bytes20(0));
        vm.assume(bytes20(salt) != bytes20(winner));

        vm.expectRevert(abi.encodeWithSelector(IUniswapV4DeployerCompetition.InvalidSender.selector, salt, winner));
        vm.prank(winner);
        competition.updateBestAddress(salt);
    }

    function test_updateBestAddress_reverts_WorseAddress(bytes32 salt) public {
        vm.assume(salt != bytes32(0));
        salt = (salt & mask20bytes) | bytes32(bytes20(winner));

        address newAddr = Create2.computeAddress(salt, initCodeHash, address(competition));
        if (!newAddr.betterThan(defaultAddress)) {
            vm.expectRevert(
                abi.encodeWithSelector(
                    IUniswapV4DeployerCompetition.WorseAddress.selector,
                    newAddr,
                    competition.bestAddress(),
                    newAddr.score(),
                    competition.bestAddress().score()
                )
            );
            vm.prank(winner);
            competition.updateBestAddress(salt);
        } else {
            vm.prank(winner);
            competition.updateBestAddress(salt);
            assertEq(competition.bestAddressSubmitter(), winner);
            assertEq(competition.bestAddressSalt(), salt);
            assertEq(competition.bestAddress(), newAddr);
        }
    }

    function test_deploy_succeeds(bytes32 salt) public {
        salt = (salt & mask20bytes) | bytes32(bytes20(winner));

        address newAddress = Create2.computeAddress(salt, initCodeHash, address(competition));
        vm.assume(newAddress.betterThan(defaultAddress));

        vm.prank(winner);
        competition.updateBestAddress(salt);
        address v4Core = competition.bestAddress();

        vm.warp(competition.competitionDeadline() + 1);
        vm.prank(deployer);
        competition.deploy(abi.encodePacked(type(PoolManager).creationCode, uint256(uint160(v4Owner))));
        assertFalse(v4Core.code.length == 0);
        assertEq(Owned(v4Core).owner(), v4Owner);
        assertEq(TickMath.MAX_TICK_SPACING, type(int16).max);
    }

    function test_deploy_reverts_CompetitionNotOver(uint256 timestamp) public {
        vm.assume(timestamp < competition.competitionDeadline());
        vm.warp(timestamp);
        vm.expectRevert(
            abi.encodeWithSelector(
                IUniswapV4DeployerCompetition.CompetitionNotOver.selector, timestamp, competition.competitionDeadline()
            )
        );
        competition.deploy(abi.encodePacked(type(PoolManager).creationCode, uint256(uint160(v4Owner))));
    }

    function test_deploy_reverts_InvalidBytecode() public {
        vm.expectRevert(IUniswapV4DeployerCompetition.InvalidBytecode.selector);
        vm.prank(deployer);
        // set the owner as the winner not the correct owner
        competition.deploy(abi.encodePacked(type(PoolManager).creationCode, uint256(uint160(winner))));
    }

    function test_deploy_reverts_NotAllowedToDeploy() public {
        vm.warp(competition.competitionDeadline() + 1);
        vm.prank(address(1));
        vm.expectRevert(
            abi.encodeWithSelector(IUniswapV4DeployerCompetition.NotAllowedToDeploy.selector, address(1), deployer)
        );
        competition.deploy(abi.encodePacked(type(PoolManager).creationCode, uint256(uint160(v4Owner))));
    }

    function test_deploy_succeeds_afterExcusiveDeployDeadline() public {
        vm.warp(competition.exclusiveDeployDeadline() + 1);
        vm.prank(address(1));
        competition.deploy(abi.encodePacked(type(PoolManager).creationCode, uint256(uint160(v4Owner))));
    }
}
