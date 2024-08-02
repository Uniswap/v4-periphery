// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";

import {PositionConfig, PositionConfigLibrary} from "../../src/libraries/PositionConfig.sol";

contract PositionConfigTest is Test {
    using PositionConfigLibrary for *;

    mapping(uint256 => bytes32) internal testConfigs;

    bytes32 public constant UPPER_BIT_SET = 0x8000000000000000000000000000000000000000000000000000000000000000;

    function test_fuzz_toId(PositionConfig calldata config) public pure {
        bytes32 expectedId = _calculateExpectedId(config);
        assertEq(expectedId, config.toId());
    }

    function test_fuzz_setConfigId(uint256 tokenId, PositionConfig calldata config) public {
        testConfigs.setConfigId(tokenId, config);

        bytes32 expectedConfigId = _calculateExpectedId(config);

        bytes32 actualConfigId = testConfigs[tokenId];
        assertEq(expectedConfigId, actualConfigId);
    }

    function test_fuzz_getConfigId(uint256 tokenId, PositionConfig calldata config) public {
        bytes32 expectedId = _calculateExpectedId(config);
        // set
        testConfigs[tokenId] = expectedId;

        assertEq(expectedId, testConfigs.getConfigId(tokenId));
    }

    function test_fuzz_setConfigId_getConfigId(uint256 tokenId, PositionConfig calldata config) public {
        testConfigs.setConfigId(tokenId, config);

        bytes32 expectedId = _calculateExpectedId(config);

        assertEq(testConfigs.getConfigId(tokenId), testConfigs[tokenId]);
        assertEq(testConfigs.getConfigId(tokenId), expectedId);
    }

    function test_fuzz_getConfigId_equal_afterSubscribe(uint256 tokenId, PositionConfig calldata config) public {
        testConfigs.setConfigId(tokenId, config);
        testConfigs.setSubscribe(tokenId);

        assertEq(testConfigs.getConfigId(tokenId), config.toId());
    }

    function test_fuzz_setSubscribe(uint256 tokenId) public {
        testConfigs.setSubscribe(tokenId);
        bytes32 upperBitSet = testConfigs[tokenId];

        assertEq(upperBitSet, UPPER_BIT_SET);
    }

    function test_fuzz_setConfigId_setSubscribe(uint256 tokenId, PositionConfig calldata config) public {
        testConfigs.setConfigId(tokenId, config);
        testConfigs.setSubscribe(tokenId);

        bytes32 expectedConfig = _calculateExpectedId(config) | UPPER_BIT_SET;

        bytes32 _config = testConfigs[tokenId];

        assertEq(_config, expectedConfig);
    }

    function test_fuzz_setUnsubscribe(uint256 tokenId) public {
        testConfigs.setSubscribe(tokenId);
        bytes32 _config = testConfigs[tokenId];
        assertEq(_config, UPPER_BIT_SET);
        testConfigs.setUnsubscribe(tokenId);
        _config = testConfigs[tokenId];
        assertEq(_config, 0);
    }

    function test_hasSubscriber(uint256 tokenId) public {
        testConfigs.setSubscribe(tokenId);
        assert(testConfigs.hasSubscriber(tokenId));
        testConfigs.setUnsubscribe(tokenId);
        assert(!testConfigs.hasSubscriber(tokenId));
    }

    function test_fuzz_setConfigId_setSubscribe_setUnsubscribe_getConfigId(
        uint256 tokenId,
        PositionConfig calldata config
    ) public {
        assertEq(testConfigs.getConfigId(tokenId), 0);

        testConfigs.setConfigId(tokenId, config);
        assertEq(testConfigs.getConfigId(tokenId), config.toId());

        testConfigs.setSubscribe(tokenId);
        assertEq(testConfigs.getConfigId(tokenId), config.toId());
        assertEq(testConfigs.hasSubscriber(tokenId), true);

        testConfigs.setUnsubscribe(tokenId);
        assertEq(testConfigs.getConfigId(tokenId), config.toId());
        assertEq(testConfigs.hasSubscriber(tokenId), false);
    }

    function _calculateExpectedId(PositionConfig calldata config) internal pure returns (bytes32 expectedId) {
        expectedId = keccak256(
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
        // truncate the upper bit
        expectedId = expectedId >> 1;
    }
}
