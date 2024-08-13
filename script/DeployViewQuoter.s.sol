// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "forge-std/console2.sol";
import "forge-std/Script.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {ViewQuoter} from "../src/lens/ViewQuoter.sol";

contract DeployViewQuoter is Script {
    function setUp() public {}

    function run(address poolManager) public returns (ViewQuoter state) {
        vm.startBroadcast();

        // forge script --broadcast --sig 'run(address)' --rpc-url <RPC_URL> --private-key <PRIV_KEY> --verify script/DeployViewQuoter.s.sol:DeployViewQuoter <POOL_MANAGER_ADDR>
        state = new ViewQuoter(IPoolManager(poolManager));
        console2.log("ViewQuoter", address(state));
        console2.log("PoolManager", address(state.poolManager()));

        vm.stopBroadcast();
    }
}
