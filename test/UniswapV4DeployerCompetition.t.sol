// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {Owned} from "solmate/src/auth/Owned.sol";
import {Test, console2} from "forge-std/Test.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {UniswapV4DeployerCompetition} from "../src/UniswapV4DeployerCompetition.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {VanityAddressLib} from "../src/libraries/VanityAddressLib.sol";
import {Create2} from "@openzeppelin/contracts/utils/Create2.sol";
import {IUniswapV4DeployerCompetition} from "../src/interfaces/IUniswapV4DeployerCompetition.sol";

contract UniswapV4DeployerCompetitionTest is Test {
    using VanityAddressLib for address;

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
        assertEq(deployer.v4Owner(), v4Owner);
    }

    function testUpdateBestAddress(bytes32 salt) public {
        assertEq(deployer.bestAddress(), address(0));
        assertEq(deployer.bestAddressSender(), address(0));
        assertEq(deployer.bestAddressSalt(), bytes32(0));

        address newAddress = Create2.computeAddress(salt, initCodeHash, address(deployer));

        vm.prank(winner);
        vm.expectEmit(true, true, true, false, address(deployer));
        emit IUniswapV4DeployerCompetition.NewAddressFound(newAddress, winner, VanityAddressLib.score(newAddress));
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
        assertEq(address(deployer).balance, 0 ether);
        assertEq(winner.balance, 1 ether);
    }

    function testCompetitionOver(bytes32 salt) public {
        vm.warp(deployer.competitionDeadline() + 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                IUniswapV4DeployerCompetition.CompetitionOver.selector, block.timestamp, deployer.competitionDeadline()
            )
        );
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
        assertEq(TickMath.MAX_TICK_SPACING, type(int16).max);
    }

    function testCompetitionNotOver(bytes32 salt, uint256 timestamp) public {
        vm.assume(timestamp < deployer.competitionDeadline());
        vm.prank(winner);
        deployer.updateBestAddress(salt);
        vm.warp(timestamp);
        vm.expectRevert(
            abi.encodeWithSelector(
                IUniswapV4DeployerCompetition.CompetitionNotOver.selector, timestamp, deployer.competitionDeadline()
            )
        );
        deployer.deploy(abi.encodePacked(type(PoolManager).creationCode, controllerGasLimit));
    }

    function testInvalidBytecode(bytes32 salt) public {
        vm.prank(winner);
        deployer.updateBestAddress(salt);
        vm.expectRevert(IUniswapV4DeployerCompetition.InvalidBytecode.selector);
        deployer.deploy(abi.encodePacked(type(PoolManager).creationCode, controllerGasLimit + 1));
    }

    function testInvalidMsgSender(bytes32 salt) public {
        vm.prank(winner);
        deployer.updateBestAddress(salt);
        vm.warp(deployer.competitionDeadline() + 1);
        vm.prank(address(1));
        vm.expectRevert(
            abi.encodeWithSelector(IUniswapV4DeployerCompetition.NotAllowedToDeploy.selector, address(1), winner)
        );
        deployer.deploy(abi.encodePacked(type(PoolManager).creationCode, controllerGasLimit));
    }

    function testAfterExcusiveDeployDeadline(bytes32 salt) public {
        vm.prank(winner);
        deployer.updateBestAddress(salt);
        vm.warp(deployer.exclusiveDeployDeadline() + 1);
        vm.prank(address(1));
        deployer.deploy(abi.encodePacked(type(PoolManager).creationCode, controllerGasLimit));
        assertEq(address(deployer).balance, 0 ether);
        assertEq(winner.balance, 1 ether);
    }

    function testEqualSaltNotChanged(bytes32 salt) public {
        vm.prank(winner);
        deployer.updateBestAddress(salt);
        assertFalse(deployer.bestAddress() == address(0));
        assertEq(deployer.bestAddressSender(), winner);
        assertEq(deployer.bestAddressSalt(), salt);

        address newAddr = Create2.computeAddress(salt >> 1, initCodeHash, address(deployer));
        vm.assume(deployer.bestAddress().betterThan(newAddr));

        vm.prank(address(1));
        vm.expectRevert(
            abi.encodeWithSelector(
                IUniswapV4DeployerCompetition.WorseAddress.selector,
                newAddr,
                deployer.bestAddress(),
                newAddr.score(),
                deployer.bestAddress().score()
            )
        );
        deployer.updateBestAddress(salt >> 1);
    }

    function testTokenURI(bytes32 salt) public {
        vm.prank(winner);
        deployer.updateBestAddress(salt);
        vm.warp(deployer.competitionDeadline() + 1);
        vm.prank(winner);
        deployer.deploy(abi.encodePacked(type(PoolManager).creationCode, controllerGasLimit));
        vm.expectRevert(abi.encodeWithSelector(IUniswapV4DeployerCompetition.InvalidTokenId.selector, 1));
        deployer.tokenURI(1);
    }
}
