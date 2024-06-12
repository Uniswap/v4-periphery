// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

struct LiquidityRange {
    PoolKey key;
    int24 tickLower;
    int24 tickUpper;
}

type LiquidityRangeId is bytes32;

/// @notice Library for computing the ID of a liquidity range
library LiquidityRangeIdLibrary {
    function toId(LiquidityRange memory position) internal pure returns (LiquidityRangeId) {
        // TODO: gas, is it better to encodePacked?
        return LiquidityRangeId.wrap(keccak256(abi.encode(position)));
    }
}
