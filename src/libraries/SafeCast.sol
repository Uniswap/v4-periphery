// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";

/// @title Safe casting methods
/// @notice Contains methods for safely casting between types
/// TODO after audits move this function to core's SafeCast.sol!
library SafeCastTemp {
    using CustomRevert for bytes4;

    error SafeCastOverflow();

    /// @notice Cast a int128 to a uint128, revert on overflow or underflow
    /// @param x The int128 to be casted
    /// @return y The casted integer, now type uint128
    function toUint128(int128 x) internal pure returns (uint128 y) {
        if (x < 0) SafeCastOverflow.selector.revertWith();
        y = uint128(x);
    }
}
