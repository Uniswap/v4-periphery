// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";

// TODO: Move to custom type, packed memory.
struct PositionInfo {
    // lower 25 bytes of the poolId
    bytes25 poolId;
    int24 tickLower;
    int24 tickUpper;
    bool hasSubscriber;
}

library PositionInfoLibrary {
    using PoolIdLibrary for PoolKey;
    /// @notice Creates the default PositionInfo struct
    /// @dev Called when minting a new position
    /// @param poolKey the pool key of the position
    /// @param tickLower the lower tick of the position
    /// @param tickUpper the upper tick of the position
    /// @return the PositionInfo struct, with the truncated poolId and the hasSubscriber flag set to false

    function initialize(PoolKey memory poolKey, int24 tickLower, int24 tickUpper)
        internal
        returns (PositionInfo memory)
    {
        return PositionInfo({
            poolId: bytes25(PoolId.unwrap(poolKey.toId())),
            tickLower: tickLower,
            tickUpper: tickUpper,
            hasSubscriber: false
        });
    }
}
