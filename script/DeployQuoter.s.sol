// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "forge-std/console2.sol";
import "forge-std/Script.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Quoter} from "../src/lens/Quoter.sol";

contract DeployQuoter is Script {
    function setUp() public {}

    function run(address poolManager) public returns (Quoter state) {
        vm.startBroadcast();

        // forge script --broadcast --sig 'run(address)' --rpc-url <RPC_URL> --private-key <PRIV_KEY> --verify script/DeployQuoter.s.sol:DeployQuoter <POOL_MANAGER_ADDR>
        state = new Quoter(IPoolManager(poolManager));
        console2.log("Quoter", address(state));
        console2.log("PoolManager", address(state.poolManager()));

        vm.stopBroadcast();
    }
}
