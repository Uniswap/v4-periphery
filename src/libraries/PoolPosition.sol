// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

// A pool position is the combination of a pool key and the position's range (tickLower, tickUpper).
struct PoolPosition {
    PoolKey poolKey;
    int24 tickLower;
    int24 tickUpper;
}

/// @notice Library for computing the positionId given a Position
/// TODO: The naming `Position` collides with v4-core use of `position` as a positionKey/positionId in core is only the hash of the poolPos, owner, and salt.
library PoolPositionLibrary {
    function toId(PoolPosition memory poolPos) internal pure returns (bytes32 id) {
        PoolKey memory poolKey = poolPos.poolKey;
        return keccak256(
            abi.encode(
                poolKey.currency0,
                poolKey.currency1,
                poolKey.fee,
                poolKey.tickSpacing,
                poolKey.hooks,
                poolPos.tickLower,
                poolPos.tickUpper
            )
        );
    }
}
