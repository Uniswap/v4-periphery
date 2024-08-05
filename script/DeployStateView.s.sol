// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "forge-std/console2.sol";
import "forge-std/Script.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateView} from "../src/lens/StateView.sol";

contract DeployStateView is Script {
    function setUp() public {}

    function run(address poolManager) public returns (StateView state) {
        vm.startBroadcast();

        // forge script --broadcast --sig 'run(address)' --rpc-url <RPC_URL> --private-key <PRIV_KEY> --verify script/DeployStateView.s.sol:DeployStateView <POOL_MANAGER_ADDR>
        state = new StateView(IPoolManager(poolManager));
        console2.log("StateView", address(state));
        console2.log("PoolManager", address(state.poolManager()));

        vm.stopBroadcast();
    }
}
