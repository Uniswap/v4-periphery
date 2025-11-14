// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

/**
 * Script: DeployPoolSwapTest
 * Purpose: Deploy core PoolSwapTest helper against an existing PoolManager
 * Usage:
 *   forge script script/03_PoolSwapTest.s.sol:DeployPoolSwapTest --rpc-url $RPC --private-key $PK --broadcast --sig "run(address)" <POOL_MANAGER>
 * Notes:
 *   Helps validate swap behavior in controlled environments.
 */

import {Script} from "forge-std/Script.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";

import "forge-std/console2.sol";

/// @title DeployPoolSwapTest Script
/// @notice Deploys PoolSwapTest bound to a PoolManager
contract DeployPoolSwapTest is Script {
    /// @notice Optional pre-run setup
    function setUp() public {}

    /// @notice Deploy the PoolSwapTest helper
    /// @param poolManager Address of the PoolManager to bind
    /// @return testSwapRouter The deployed helper instance
    function run(address poolManager) public returns (PoolSwapTest testSwapRouter) {
        vm.broadcast();
        testSwapRouter = new PoolSwapTest(IPoolManager(poolManager));
        console2.log("PoolSwapTest", address(testSwapRouter));
    }
}
