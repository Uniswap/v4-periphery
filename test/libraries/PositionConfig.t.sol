// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {PositionConfig, PositionConfigLibrary} from "../../src/libraries/PositionConfig.sol";

contract PositionConfigTest is Test {
    using PositionConfigLibrary for PositionConfig;

    function test_fuzz_toId(PositionConfig calldata config) public {
        bytes32 expectedId = keccak256(
            abi.encodePacked(
                config.poolKey.currency0,
                config.poolKey.currency1,
                config.poolKey.fee,
                config.poolKey.tickSpacing,
                config.poolKey.hooks,
                config.tickLower,
                config.tickUpper
            )
        );
        assertEq(expectedId, config.toId());
    }
}
