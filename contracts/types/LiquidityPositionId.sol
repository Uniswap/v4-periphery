// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

// TODO: move into core? some of the mappings / pool.state seem to hash position id's
struct LiquidityPosition {
    PoolKey key;
    int24 tickLower;
    int24 tickUpper;
}

type LiquidityPositionId is bytes32;

/// @notice Library for computing the ID of a pool
library LiquidityPositionIdLibrary {
    function toId(LiquidityPosition memory position) internal pure returns (LiquidityPositionId) {
        // TODO: gas, is it better to encodePacked?
        return LiquidityPositionId.wrap(keccak256(abi.encode(position)));
    }
}
