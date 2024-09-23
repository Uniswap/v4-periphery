// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "forge-std/console2.sol";
import "forge-std/Script.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PositionDescriptor} from "../src/PositionDescriptor.sol";

contract DeployPositionDescriptorTest is Script {
    function setUp() public {}

    function run(address poolManager, address weth, string memory nativeCurrencyLabel)
        public
        returns (PositionDescriptor positionDescriptor)
    {
        vm.startBroadcast();

        positionDescriptor = new PositionDescriptor(IPoolManager(poolManager), weth, nativeCurrencyLabel);
        console2.log("PositionDescriptor", address(positionDescriptor));

        vm.stopBroadcast();
    }
}
