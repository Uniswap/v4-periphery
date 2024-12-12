// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {PositionManager} from "../../src/PositionManager.sol";

contract PositionManagerInitCodeHashTest is Test {
    function setUp() public {}

    function test_initcodeHash() public {
        vm.snapshotValue(
            "positionManager initcode hash (without constructor params, as uint256)",
            uint256(keccak256(type(PositionManager).creationCode))
        );
    }
}
