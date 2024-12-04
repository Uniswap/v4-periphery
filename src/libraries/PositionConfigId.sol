// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @notice A configId is set per tokenId
/// The lower 255 bits are used to store the truncated hash of the corresponding PositionConfig
/// The upper bit is used to signal if the tokenId has a subscriber
struct PositionConfigId {
    bytes32 id;
}

library PositionConfigIdLibrary {
    bytes32 constant MASK_UPPER_BIT = 0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF;
    bytes32 constant DIRTY_UPPER_BIT = 0x8000000000000000000000000000000000000000000000000000000000000000;

    /// @notice returns the truncated hash of the PositionConfig for a given tokenId
    function getConfigId(PositionConfigId storage _configId) internal view returns (bytes32 configId) {
        configId = _configId.id & MASK_UPPER_BIT;
    }

    /// @dev We only set the config on mint, guaranteeing that the most significant bit is unset, so we can just assign the entire 32 bytes to the id.
    function setConfigId(PositionConfigId storage _configId, bytes32 configId) internal {
        _configId.id = configId;
    }

    function setSubscribe(PositionConfigId storage configId) internal {
        configId.id |= DIRTY_UPPER_BIT;
    }

    function setUnsubscribe(PositionConfigId storage configId) internal {
        configId.id &= MASK_UPPER_BIT;
    }

    function hasSubscriber(PositionConfigId storage configId) internal view returns (bool subscribed) {
        bytes32 _id = configId.id;
        assembly ("memory-safe") {
            subscribed := shr(255, _id)
        }
    }
}
