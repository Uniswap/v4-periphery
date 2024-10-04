// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "forge-std/console2.sol";
import "forge-std/Script.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateView} from "../src/lens/StateView.sol";
import {PositionManager} from "../src/PositionManager.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {IPositionDescriptor} from "../src/interfaces/IPositionDescriptor.sol";
import {PositionDescriptor} from "../src/PositionDescriptor.sol";

contract DeployPosmTest is Script {
    function setUp() public {}

    function run(
        address poolManager,
        address permit2,
        uint256 unsubscribeGasLimit,
        address wrappedNative,
        string memory nativeCurrencyLabel
    ) public returns (PositionDescriptor positionDescriptor, PositionManager posm) {
        vm.startBroadcast();

        positionDescriptor = new PositionDescriptor(IPoolManager(poolManager), wrappedNative, nativeCurrencyLabel);
        console2.log("PositionDescriptor", address(positionDescriptor));

        posm = new PositionManager{salt: hex"03"}(
            IPoolManager(poolManager),
            IAllowanceTransfer(permit2),
            unsubscribeGasLimit,
            IPositionDescriptor(address(positionDescriptor))
        );
        console2.log("PositionManager", address(posm));

        vm.stopBroadcast();
    }
}
