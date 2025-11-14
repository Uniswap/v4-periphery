// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * Script: DeployStateView
 * Purpose: Deploy read-only StateView lens bound to a PoolManager
 * Usage:
 *   forge script script/DeployStateView.s.sol:DeployStateView --rpc-url $RPC --private-key $PK --broadcast --sig "run(address)" <POOL_MANAGER>
 */

import "forge-std/console2.sol";
import "forge-std/Script.sol";

import {Deploy, IStateView} from "../test/shared/Deploy.sol";

/// @title DeployStateView Script
/// @notice Deploys StateView bound to a PoolManager
contract DeployStateView is Script {
    /// @notice Optional pre-run setup
    function setUp() public {}

    /// @notice Deploy the StateView lens
    /// @param poolManager PoolManager address
    /// @return state The deployed StateView instance
    function run(address poolManager) public returns (IStateView state) {
        vm.startBroadcast();

        // forge script --broadcast --sig 'run(address)' --rpc-url <RPC_URL> --private-key <PRIV_KEY> --verify script/DeployStateView.s.sol:DeployStateView <POOL_MANAGER_ADDR>
        state = Deploy.stateView(poolManager, hex"00");
        console2.log("StateView", address(state));
        console2.log("PoolManager", address(state.poolManager()));

        vm.stopBroadcast();
    }
}
