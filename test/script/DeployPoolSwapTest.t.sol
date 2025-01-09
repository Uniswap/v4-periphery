// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {DeployPoolSwapTest} from "../../script/03_PoolSwapTest.s.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {Test} from "forge-std/Test.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";

// Test of a Test contract (lol)
contract DeployPoolSwapTestTest is Test {
    DeployPoolSwapTest deployer;

    IPoolManager manager;

    function setUp() public {
        manager = new PoolManager(address(this));
        deployer = new DeployPoolSwapTest();
    }

    function test_run_testSwapRouter() public {
        PoolSwapTest testSwapRouter = deployer.run(address(manager));

        assertEq(address(testSwapRouter.manager()), address(manager));
    }
}
