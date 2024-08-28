// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

library PoolKeyChecker {
    // On UniswapV4, the minimum tick spacing is 1.
    // This means that if the tick spacing is 0, the pool key has not been set.
    function isEmpty(PoolKey memory poolKey) internal pure returns (bool) {
        return poolKey.tickSpacing == 0;
    }
}
