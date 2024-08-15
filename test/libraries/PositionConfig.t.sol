// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";

import {PositionConfig, PositionConfigLibrary} from "../../src/libraries/PositionConfig.sol";
import {PositionConfigId, PositionConfigIdLibrary} from "../../src/libraries/PositionConfigId.sol";

contract PositionConfigTest is Test {
    using PositionConfigLibrary for PositionConfig;
    using PositionConfigIdLibrary for PositionConfigId;

    mapping(uint256 => PositionConfigId) internal testConfigs;

    bytes32 public constant UPPER_BIT_SET = 0x8000000000000000000000000000000000000000000000000000000000000000;

    function test_fuzz_toId(PositionConfig calldata config) public pure {
        bytes32 expectedId = _calculateExpectedId(config);
        assertEq(expectedId, config.toId());
    }

    function test_fuzz_setConfigId(uint256 tokenId, PositionConfig calldata config) public {
        testConfigs[tokenId].setConfigId(config.toId());

        bytes32 expectedConfigId = _calculateExpectedId(config);

        bytes32 actualConfigId = testConfigs[tokenId].id;
        assertEq(expectedConfigId, actualConfigId);
    }

    function test_fuzz_getConfigId(uint256 tokenId, PositionConfig calldata config) public {
        bytes32 expectedId = _calculateExpectedId(config);
        // set
        testConfigs[tokenId] = PositionConfigId({id: expectedId});

        assertEq(expectedId, testConfigs[tokenId].getConfigId());
    }

    function test_fuzz_setConfigId_getConfigId(uint256 tokenId, PositionConfig calldata config) public {
        testConfigs[tokenId].setConfigId(config.toId());

        bytes32 expectedId = _calculateExpectedId(config);

        assertEq(testConfigs[tokenId].getConfigId(), testConfigs[tokenId].id);
        assertEq(testConfigs[tokenId].getConfigId(), expectedId);
    }

    function test_fuzz_getConfigId_equal_afterSubscribe(uint256 tokenId, PositionConfig calldata config) public {
        testConfigs[tokenId].setConfigId(config.toId());
        testConfigs[tokenId].setSubscribe();

        assertEq(testConfigs[tokenId].getConfigId(), config.toId());
    }

    function test_fuzz_setSubscribe(uint256 tokenId) public {
        testConfigs[tokenId].setSubscribe();
        bytes32 upperBitSet = testConfigs[tokenId].id;

        assertEq(upperBitSet, UPPER_BIT_SET);
    }

    function test_fuzz_setConfigId_setSubscribe(uint256 tokenId, PositionConfig calldata config) public {
        testConfigs[tokenId].setConfigId(config.toId());
        testConfigs[tokenId].setSubscribe();

        bytes32 expectedConfig = _calculateExpectedId(config) | UPPER_BIT_SET;

        bytes32 _config = testConfigs[tokenId].id;

        assertEq(_config, expectedConfig);
    }

    function test_fuzz_setUnsubscribe(uint256 tokenId) public {
        testConfigs[tokenId].setSubscribe();
        bytes32 _config = testConfigs[tokenId].id;
        assertEq(_config, UPPER_BIT_SET);
        testConfigs[tokenId].setUnsubscribe();
        _config = testConfigs[tokenId].id;
        assertEq(_config, 0);
    }

    function test_hasSubscriber(uint256 tokenId) public {
        testConfigs[tokenId].setSubscribe();
        assert(testConfigs[tokenId].hasSubscriber());
        testConfigs[tokenId].setUnsubscribe();
        assert(!testConfigs[tokenId].hasSubscriber());
    }

    function test_fuzz_setConfigId_setSubscribe_setUnsubscribe_getConfigId(
        uint256 tokenId,
        PositionConfig calldata config
    ) public {
        assertEq(testConfigs[tokenId].getConfigId(), 0);

        testConfigs[tokenId].setConfigId(config.toId());
        assertEq(testConfigs[tokenId].getConfigId(), config.toId());

        testConfigs[tokenId].setSubscribe();
        assertEq(testConfigs[tokenId].getConfigId(), config.toId());
        assertEq(testConfigs[tokenId].hasSubscriber(), true);

        testConfigs[tokenId].setUnsubscribe();
        assertEq(testConfigs[tokenId].getConfigId(), config.toId());
        assertEq(testConfigs[tokenId].hasSubscriber(), false);
    }

    function test_fuzz_setSubscribe_twice(uint256 tokenId, PositionConfig calldata config) public {
        assertFalse(testConfigs[tokenId].hasSubscriber());

        testConfigs[tokenId].setSubscribe();
        testConfigs[tokenId].setSubscribe();
        assertTrue(testConfigs[tokenId].hasSubscriber());

        // It is known behavior that setting the config id just stores the id directly, meaning the upper most bit is unset.
        // This is ok because setConfigId will only ever be called on mint.
        testConfigs[tokenId].setConfigId(config.toId());
        assertFalse(testConfigs[tokenId].hasSubscriber());

        testConfigs[tokenId].setSubscribe();
        testConfigs[tokenId].setSubscribe();
        assertTrue(testConfigs[tokenId].hasSubscriber());
    }

    function test_fuzz_setUnsubscribe_twice(uint256 tokenId, PositionConfig calldata config) public {
        assertFalse(testConfigs[tokenId].hasSubscriber());

        testConfigs[tokenId].setUnsubscribe();
        testConfigs[tokenId].setUnsubscribe();
        assertFalse(testConfigs[tokenId].hasSubscriber());

        testConfigs[tokenId].setConfigId(config.toId());
        assertFalse(testConfigs[tokenId].hasSubscriber());

        testConfigs[tokenId].setUnsubscribe();
        testConfigs[tokenId].setUnsubscribe();
        assertFalse(testConfigs[tokenId].hasSubscriber());

        testConfigs[tokenId].setSubscribe();
        assertTrue(testConfigs[tokenId].hasSubscriber());

        testConfigs[tokenId].setUnsubscribe();
        testConfigs[tokenId].setUnsubscribe();
        assertFalse(testConfigs[tokenId].hasSubscriber());
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
