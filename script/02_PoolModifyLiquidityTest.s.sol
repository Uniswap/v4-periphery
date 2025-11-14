// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

/**
 * Script: DeployPoolModifyLiquidityTest
 * Purpose: Deploy core PoolModifyLiquidityTest helper against an existing PoolManager
 * Usage:
 *   forge script script/02_PoolModifyLiquidityTest.s.sol:DeployPoolModifyLiquidityTest --rpc-url $RPC --private-key $PK --broadcast --sig "run(address)" <POOL_MANAGER>
 * Notes:
 *   Useful for exercising liquidity flows in local/testing environments.
 */

import {Script} from "forge-std/Script.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";

import "forge-std/console2.sol";

/// @title DeployPoolModifyLiquidityTest Script
/// @notice Deploys PoolModifyLiquidityTest bound to a PoolManager
contract DeployPoolModifyLiquidityTest is Script {
    /// @notice Optional pre-run setup
    function setUp() public {}

    /// @notice Deploy the PoolModifyLiquidityTest helper
    /// @param poolManager Address of the PoolManager to bind
    /// @return testModifyRouter The deployed helper instance
    function run(address poolManager) public returns (PoolModifyLiquidityTest testModifyRouter) {
        vm.broadcast();
        testModifyRouter = new PoolModifyLiquidityTest(IPoolManager(poolManager));
        console2.log("PoolModifyLiquidityTest", address(testModifyRouter));
    }
}
