// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/console2.sol";
import "forge-std/Script.sol";

import {Deploy, IStateView} from "../test/shared/Deploy.sol";

contract DeployStateView is Script {
    function setUp() public {}

    function run(address poolManager) public returns (IStateView state) {
        vm.startBroadcast();

        // forge script --broadcast --sig 'run(address)' --rpc-url <RPC_URL> --private-key <PRIV_KEY> --verify script/DeployStateView.s.sol:DeployStateView <POOL_MANAGER_ADDR>
        state = Deploy.stateView(poolManager, hex"00");
        console2.log("StateView", address(state));
        console2.log("PoolManager", address(state.poolManager()));

        vm.stopBroadcast();
    }
}
