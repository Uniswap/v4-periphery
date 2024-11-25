// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Script} from "forge-std/Script.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";

import "forge-std/console2.sol";

contract DeployPoolModifyLiquidityTest is Script {
    function setUp() public {}

    function run(address poolManager) public returns (PoolModifyLiquidityTest testModifyRouter) {
        vm.broadcast();
        testModifyRouter = new PoolModifyLiquidityTest(IPoolManager(poolManager));
        console2.log("PoolModifyLiquidityTest", address(testModifyRouter));
    }
}
