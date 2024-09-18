// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";

/// @title Pool Ticks Counter
/// @notice Functions for counting the number of initialized ticks between two ticks
library PoolTicksCounter {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    struct TickCache {
        int16 wordPosLower;
        int16 wordPosHigher;
        uint8 bitPosLower;
        uint8 bitPosHigher;
        bool tickBeforeInitialized;
        bool tickAfterInitialized;
    }

    /// @notice Count the number of initialized ticks between two ticks
    /// @dev This function counts the number of initialized ticks that would incur a gas cost between tickBefore and tickAfter.
    /// When tickBefore and/or tickAfter themselves are initialized, the logic over whether we should count them depends on the
    /// direction of the swap. If we are swapping upwards (tickAfter > tickBefore) we don't want to count tickBefore but we do
    /// want to count tickAfter. The opposite is true if we are swapping downwards.
    /// @param self the IPoolManager
    /// @param key the PoolKey of the pool
    /// @param tickBefore the tick before the swap
    /// @param tickAfter the tick after the swap
    /// @return initializedTicksLoaded the number of initialized ticks loaded
    function countInitializedTicksLoaded(IPoolManager self, PoolKey memory key, int24 tickBefore, int24 tickAfter)
        internal
        view
        returns (uint32 initializedTicksLoaded)
    {
        TickCache memory cache;

        {
            // Get the key and offset in the tick bitmap of the active tick before and after the swap.
            int16 wordPos = int16((tickBefore / key.tickSpacing) >> 8);
            uint8 bitPos = uint8(uint24((tickBefore / key.tickSpacing) % 256));

            int16 wordPosAfter = int16((tickAfter / key.tickSpacing) >> 8);
            uint8 bitPosAfter = uint8(uint24((tickAfter / key.tickSpacing) % 256));

            // In the case where tickAfter is initialized, we only want to count it if we are swapping downwards.
            // If the initializable tick after the swap is initialized, our original tickAfter is a
            // multiple of tick spacing, and we are swapping downwards we know that tickAfter is initialized
            // and we shouldn't count it.
            uint256 bmAfter = self.getTickBitmap(key.toId(), wordPosAfter);
            cache.tickAfterInitialized =
                ((bmAfter & (1 << bitPosAfter)) > 0) && ((tickAfter % key.tickSpacing) == 0) && (tickBefore > tickAfter);

            // In the case where tickBefore is initialized, we only want to count it if we are swapping upwards.
            // Use the same logic as above to decide whether we should count tickBefore or not.
            uint256 bmBefore = self.getTickBitmap(key.toId(), wordPos);
            cache.tickBeforeInitialized =
                ((bmBefore & (1 << bitPos)) > 0) && ((tickBefore % key.tickSpacing) == 0) && (tickBefore < tickAfter);

            if (wordPos < wordPosAfter || (wordPos == wordPosAfter && bitPos <= bitPosAfter)) {
                cache.wordPosLower = wordPos;
                cache.bitPosLower = bitPos;
                cache.wordPosHigher = wordPosAfter;
                cache.bitPosHigher = bitPosAfter;
            } else {
                cache.wordPosLower = wordPosAfter;
                cache.bitPosLower = bitPosAfter;
                cache.wordPosHigher = wordPos;
                cache.bitPosHigher = bitPos;
            }
        }

        // Count the number of initialized ticks crossed by iterating through the tick bitmap.
        // Our first mask should include the lower tick and everything to its left.
        uint256 mask = type(uint256).max << cache.bitPosLower;
        while (cache.wordPosLower <= cache.wordPosHigher) {
            // If we're on the final tick bitmap page, ensure we only count up to our
            // ending tick.
            if (cache.wordPosLower == cache.wordPosHigher) {
                mask = mask & (type(uint256).max >> (255 - cache.bitPosHigher));
            }

            uint256 bmLower = self.getTickBitmap(key.toId(), cache.wordPosLower);
            uint256 masked = bmLower & mask;
            initializedTicksLoaded += countOneBits(masked);
            cache.wordPosLower++;
            // Reset our mask so we consider all bits on the next iteration.
            mask = type(uint256).max;
        }

        if (cache.tickAfterInitialized) {
            initializedTicksLoaded -= 1;
        }

        if (cache.tickBeforeInitialized) {
            initializedTicksLoaded -= 1;
        }

        return initializedTicksLoaded;
    }

    /// @notice Count the number of set bits in a uint256
    /// @param x the uint256 to count the bits of
    function countOneBits(uint256 x) private pure returns (uint16) {
        uint16 bits = 0;
        while (x != 0) {
            bits++;
            x &= (x - 1);
        }
        return bits;
    }
}
