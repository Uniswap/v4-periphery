// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.24;

/// @notice Library for negating a uint256 value.
/// Used for decreasing liquidity on a pool.
/// @dev It is safe to negate in an unchecked block because liquidity is always postive (uint256)
library LiquidityNegation {
    function toNegativeInt256(uint256 liquidity) internal pure returns (int256 liquidityDelta) {
        unchecked {
            liquidityDelta = -int256(liquidity);
        }
    }
}
