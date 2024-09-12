// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

library SqrtPriceLimitHelper {
    /// @dev return either the sqrtPriceLimit from user input, or the max/min value possible depending on trade direction
    function getSqrtPriceLimit(uint160 sqrtPriceLimitX96, bool zeroForOne) internal pure returns (uint160) {
        return sqrtPriceLimitX96 == 0
            ? zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            : sqrtPriceLimitX96;
    }
}
