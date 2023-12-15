// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.8.20;

import {PoolGetters} from "./PoolGetters.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";

library PoolTicksCounter {
    using PoolIdLibrary for PoolKey;

    /// @dev This function counts the number of initialized ticks that would incur a gas cost between tickBefore and tickAfter.
    /// When tickBefore and/or tickAfter themselves are initialized, the logic over whether we should count them depends on the
    /// direction of the swap. If we are swapping upwards (tickAfter > tickBefore) we don't want to count tickBefore but we do
    /// want to count tickAfter. The opposite is true if we are swapping downwards.
    function countInitializedTicksLoaded(IPoolManager self, PoolKey memory key, int24 tickBefore, int24 tickAfter)
        internal
        view
        returns (uint32 initializedTicksLoaded)
    {
        int16 wordPosLower;
        int16 wordPosHigher;
        uint8 bitPosLower;
        uint8 bitPosHigher;
        bool tickBeforeInitialized;
        bool tickAfterInitialized;

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
            uint256 bmAfter = self.getPoolBitmapInfo(key.toId(), wordPosAfter);
            //uint256 bmAfter = PoolGetters.getTickBitmapAtWord(self, key.toId(), wordPosAfter);
            tickAfterInitialized =
                ((bmAfter & (1 << bitPosAfter)) > 0) && ((tickAfter % key.tickSpacing) == 0) && (tickBefore > tickAfter);

            // In the case where tickBefore is initialized, we only want to count it if we are swapping upwards.
            // Use the same logic as above to decide whether we should count tickBefore or not.
            uint256 bmBefore = self.getPoolBitmapInfo(key.toId(), wordPos);
            //uint256 bmBefore = PoolGetters.getTickBitmapAtWord(self, key.toId(), wordPos);
            tickBeforeInitialized =
                ((bmBefore & (1 << bitPos)) > 0) && ((tickBefore % key.tickSpacing) == 0) && (tickBefore < tickAfter);

            if (wordPos < wordPosAfter || (wordPos == wordPosAfter && bitPos <= bitPosAfter)) {
                wordPosLower = wordPos;
                bitPosLower = bitPos;
                wordPosHigher = wordPosAfter;
                bitPosHigher = bitPosAfter;
            } else {
                wordPosLower = wordPosAfter;
                bitPosLower = bitPosAfter;
                wordPosHigher = wordPos;
                bitPosHigher = bitPos;
            }
        }

        // Count the number of initialized ticks crossed by iterating through the tick bitmap.
        // Our first mask should include the lower tick and everything to its left.
        uint256 mask = type(uint256).max << bitPosLower;
        while (wordPosLower <= wordPosHigher) {
            // If we're on the final tick bitmap page, ensure we only count up to our
            // ending tick.
            if (wordPosLower == wordPosHigher) {
                mask = mask & (type(uint256).max >> (255 - bitPosHigher));
            }

            //uint256 bmLower = PoolGetters.getTickBitmapAtWord(self, key.toId(), wordPosLower);
            uint256 bmLower = self.getPoolBitmapInfo(key.toId(), wordPosLower);
            uint256 masked = bmLower & mask;
            initializedTicksLoaded += countOneBits(masked);
            wordPosLower++;
            // Reset our mask so we consider all bits on the next iteration.
            mask = type(uint256).max;
        }

        if (tickAfterInitialized) {
            initializedTicksLoaded -= 1;
        }

        if (tickBeforeInitialized) {
            initializedTicksLoaded -= 1;
        }

        return initializedTicksLoaded;
    }

    function countOneBits(uint256 x) private pure returns (uint16) {
        uint16 bits = 0;
        while (x != 0) {
            bits++;
            x &= (x - 1);
        }
        return bits;
    }
}
