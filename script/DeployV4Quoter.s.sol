// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * Script: DeployV4Quoter
 * Purpose: Deploy V4Quoter bound to a PoolManager for off-chain quoting
 * Usage:
 *   forge script script/DeployV4Quoter.s.sol:DeployV4Quoter --rpc-url $RPC --private-key $PK --broadcast 
 *   --sig "run(address)" <POOL_MANAGER>
 * Notes:
 *   V4Quoter performs revert-encoded simulations and is intended for off-chain use.
 */

import "forge-std/console2.sol";
import "forge-std/Script.sol";

import {Deploy, IV4Quoter} from "../test/shared/Deploy.sol";

/// @title DeployV4Quoter Script
/// @notice Deploys V4Quoter bound to a given PoolManager for off-chain quoting
/// @dev Uses Foundry broadcast; V4Quoter is intended for off-chain simulation
contract DeployV4Quoter is Script {
    /// @notice Optional pre-run setup for the script
    function setUp() public {}

    /// @notice Deploy the V4Quoter contract
    /// @param poolManager The Uniswap v4 PoolManager address to bind the quoter to
    /// @return state The deployed IV4Quoter instance
    function run(address poolManager) public returns (IV4Quoter state) {
        vm.startBroadcast();

        // Broadcast, deploy V4Quoter bound to poolManager, and log addresses
        state = Deploy.v4Quoter(poolManager, hex"00");
        console2.log("V4Quoter", address(state));
        console2.log("PoolManager", address(state.poolManager()));

        vm.stopBroadcast();
    }
}
