// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

// A PositionConfig is the input for creating and modifying a Position in core, set per tokenId
struct PositionConfig {
    PoolKey poolKey;
    int24 tickLower;
    int24 tickUpper;
}

/// @notice Library for computing the configId given a PositionConfig
library PositionConfigLibrary {
    function toId(PositionConfig memory config) internal pure returns (bytes32 id) {
        PoolKey memory poolKey = config.poolKey;
        return keccak256(
            abi.encodePacked(
                poolKey.currency0,
                poolKey.currency1,
                poolKey.fee,
                poolKey.tickSpacing,
                poolKey.hooks,
                config.tickLower,
                config.tickUpper
            )
        );
    }
}
