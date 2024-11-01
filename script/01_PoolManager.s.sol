// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

import "forge-std/console2.sol";

contract DeployPoolManager is Script {
    function setUp() public {}

    function run() public returns (IPoolManager manager) {
        vm.startBroadcast();

        manager = new PoolManager(msg.sender);
        console2.log("PoolManager", address(manager));
        console2.log("PoolManager Owner", msg.sender);

        vm.stopBroadcast();
    }
}
