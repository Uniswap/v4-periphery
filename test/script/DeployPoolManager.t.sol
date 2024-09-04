// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {DeployPoolManager} from "../../script/01_PoolManager.s.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Test} from "forge-std/Test.sol";

contract DeployPoolManagerTest is Test {
    DeployPoolManager deployer;

    function setUp() public {
        deployer = new DeployPoolManager();
    }

    function test_run_poolManager() public {
        IPoolManager manager = deployer.run();
        // Foundry sets a default sender in scripts.
        address defaultSender = 0x1804c8AB1F12E6bbf3894d4083f33e07309d1f38;
        // Deployer is the owner.
        assertEq(_getOwner(manager), defaultSender);
    }

    function _getOwner(IPoolManager manager) public view returns (address owner) {
        // owner is at slot 0
        owner = address(uint160(uint256(manager.extsload(0))));
    }
}
