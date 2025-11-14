// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * Script: DeployPoolManager
 * Purpose: Deploy Uniswap v4 PoolManager and log its address
 * Usage:
 *   forge script script/01_PoolManager.s.sol:DeployPoolManager --rpc-url $RPC --private-key $PK --broadcast
 * Notes:
 *   PoolManager constructor takes an owner/controller; this script passes its own address.
 */

import "forge-std/Script.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

import "forge-std/console2.sol";

/// @title DeployPoolManager Script
/// @notice Deploys PoolManager and prints its address
contract DeployPoolManager is Script {
    /// @notice Optional pre-run setup
    function setUp() public {}

    /// @notice Deploy PoolManager
    /// @return manager The deployed PoolManager instance
    function run() public returns (IPoolManager manager) {
        vm.startBroadcast();

        manager = new PoolManager(address(this));
        console2.log("PoolManager", address(manager));

        vm.stopBroadcast();
    }
}
