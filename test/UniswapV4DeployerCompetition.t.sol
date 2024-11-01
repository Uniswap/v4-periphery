// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {Owned} from "solmate/src/auth/Owned.sol";
import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
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
    uint256 competitionDeadline;

    bytes32 mask20bytes = bytes32(uint256(type(uint96).max));

    function setUp() public {
        competitionDeadline = block.timestamp + 7 days;
        v4Owner = makeAddr("V4Owner");
        winner = makeAddr("Winner");
        deployer = makeAddr("Deployer");
        vm.prank(deployer);
        initCodeHash = keccak256(abi.encodePacked(type(PoolManager).creationCode, uint256(uint160(v4Owner))));
        competition = new UniswapV4DeployerCompetition(initCodeHash, v4Owner, competitionDeadline);
        assertEq(competition.v4Owner(), v4Owner);
    }

    function test_updateBestAddress_succeeds(bytes32 salt) public {
        salt = (salt & mask20bytes) | bytes32(bytes20(winner));

        assertEq(competition.bestAddress(), address(0));
        assertEq(competition.bestAddressSubmitter(), address(0));
        assertEq(competition.bestAddressSalt(), bytes32(0));

        address newAddress = Create2.computeAddress(salt, initCodeHash, address(competition));

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

    function test_updateBestAddress_equalSalt_reverts_WorseAddress(bytes32 salt) public {
        vm.assume(salt != bytes32(0));
        console2.logBytes32(salt);
        salt = (salt & mask20bytes) | bytes32(bytes20(winner));
        console2.logBytes32(salt);

        vm.prank(winner);
        competition.updateBestAddress(salt);
        assertFalse(competition.bestAddress() == address(0));
        assertEq(competition.bestAddressSubmitter(), winner);
        assertEq(competition.bestAddressSalt(), salt);

        bytes32 newSalt = (salt & mask20bytes) | bytes32(bytes20(address(1)));
        address newAddr = Create2.computeAddress(newSalt, initCodeHash, address(competition));
        if (!newAddr.betterThan(competition.bestAddress())) {
            vm.expectRevert(
                abi.encodeWithSelector(
                    IUniswapV4DeployerCompetition.WorseAddress.selector,
                    newAddr,
                    competition.bestAddress(),
                    newAddr.score(),
                    competition.bestAddress().score()
                )
            );
            vm.prank(address(1));
            competition.updateBestAddress(newSalt);
        } else {
            vm.prank(address(1));
            competition.updateBestAddress(newSalt);
            assertEq(competition.bestAddressSubmitter(), address(1));
            assertEq(competition.bestAddressSalt(), newSalt);
        }
    }

    function test_deploy_succeeds(bytes32 salt) public {
        salt = (salt & mask20bytes) | bytes32(bytes20(winner));

        vm.prank(winner);
        competition.updateBestAddress(salt);
        address v4Core = competition.bestAddress();

        vm.warp(competition.competitionDeadline() + 1.1 days);
        competition.deploy(abi.encodePacked(type(PoolManager).creationCode, uint256(uint160(v4Owner))));
        assertFalse(v4Core.code.length == 0);
        assertEq(Owned(v4Core).owner(), v4Owner);
        assertEq(TickMath.MAX_TICK_SPACING, type(int16).max);
    }

    function test_deploy_reverts_CompetitionNotOver(bytes32 salt, uint256 timestamp) public {
        salt = (salt & mask20bytes) | bytes32(bytes20(winner));

        vm.assume(timestamp < competition.competitionDeadline());
        vm.prank(winner);
        competition.updateBestAddress(salt);
        vm.warp(timestamp);
        vm.expectRevert(
            abi.encodeWithSelector(
                IUniswapV4DeployerCompetition.CompetitionNotOver.selector, timestamp, competition.competitionDeadline()
            )
        );
        competition.deploy(abi.encodePacked(type(PoolManager).creationCode, uint256(uint160(v4Owner))));
    }

    function test_deploy_reverts_InvalidBytecode(bytes32 salt) public {
        salt = (salt & mask20bytes) | bytes32(bytes20(winner));

        vm.prank(winner);
        competition.updateBestAddress(salt);
        vm.expectRevert(IUniswapV4DeployerCompetition.InvalidBytecode.selector);
        // set the owner as the winner not the correct owner
        competition.deploy(abi.encodePacked(type(PoolManager).creationCode, uint256(uint160(winner))));
    }

    function test_deploy_reverts_InvalidMsgSender(bytes32 salt) public {
        salt = (salt & mask20bytes) | bytes32(bytes20(winner));

        vm.prank(winner);
        competition.updateBestAddress(salt);
        vm.warp(competition.competitionDeadline() + 1);
        vm.prank(address(1));
        vm.expectRevert(
            abi.encodeWithSelector(IUniswapV4DeployerCompetition.NotAllowedToDeploy.selector, address(1), deployer)
        );
        competition.deploy(abi.encodePacked(type(PoolManager).creationCode, uint256(uint160(v4Owner))));
    }

    function test_deploy_afterExcusiveDeployDeadline(bytes32 salt) public {
        salt = (salt & mask20bytes) | bytes32(bytes20(winner));

        vm.prank(winner);
        competition.updateBestAddress(salt);
        vm.warp(competition.exclusiveDeployDeadline() + 1);
        vm.prank(address(1));
        competition.deploy(abi.encodePacked(type(PoolManager).creationCode, uint256(uint160(v4Owner))));
    }
}
