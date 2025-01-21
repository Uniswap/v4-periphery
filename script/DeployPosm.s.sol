// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/console2.sol";
import "forge-std/Script.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {Deploy, IPositionDescriptor, IPositionManager} from "../test/shared/Deploy.sol";
import {IWETH9} from "../src/interfaces/external/IWETH9.sol";

contract DeployPosmTest is Script {
    function setUp() public {}

    function run(
        address poolManager,
        address permit2,
        uint256 unsubscribeGasLimit,
        address wrappedNative,
        bytes32 nativeCurrencyLabelBytes
    ) public returns (IPositionDescriptor positionDescriptor, IPositionManager posm) {
        vm.startBroadcast();

        positionDescriptor = Deploy.positionDescriptor(poolManager, wrappedNative, nativeCurrencyLabelBytes, hex"00");
        console2.log("PositionDescriptor", address(positionDescriptor));

        posm = Deploy.positionManager(
            poolManager, permit2, unsubscribeGasLimit, address(positionDescriptor), wrappedNative, hex"03"
        );
        console2.log("PositionManager", address(posm));

        vm.stopBroadcast();
    }
}
