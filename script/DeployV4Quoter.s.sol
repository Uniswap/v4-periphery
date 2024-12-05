// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/console2.sol";
import "forge-std/Script.sol";

import {Deploy, IV4Quoter} from "../test/shared/Deploy.sol";

contract DeployV4Quoter is Script {
    function setUp() public {}

    function run(address poolManager) public returns (IV4Quoter state) {
        vm.startBroadcast();

        // forge script --broadcast --sig 'run(address)' --rpc-url <RPC_URL> --private-key <PRIV_KEY> --verify script/DeployV4Quoter.s.sol:DeployV4Quoter <POOL_MANAGER_ADDR>
        state = Deploy.v4Quoter(poolManager, hex"00");
        console2.log("V4Quoter", address(state));
        console2.log("PoolManager", address(state.poolManager()));

        vm.stopBroadcast();
    }
}
