// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {IPoolManager} from "@uniswap/v4-core/contracts/interfaces/IPoolManager.sol";
import {Pool} from "@uniswap/v4-core/contracts/libraries/Pool.sol";
import {Position} from "@uniswap/v4-core/contracts/libraries/Position.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/contracts/types/PoolId.sol";
import {BitMath} from "@uniswap/v4-core/contracts/libraries/BitMath.sol";

/// @title Helper functions to access pool information
library PoolGetters {
    uint256 constant POOL_SLOT = 10; // does this work ? isnt pool slot 4? in pool manager it's also 10
    uint256 constant TICKS_OFFSET = 4;
    uint256 constant TICK_BITMAP_OFFSET = 5;
    uint256 constant POSITIONS_OFFSET = 6;

    function getPoolSqrtPrice(IPoolManager poolManager, PoolId poolId) internal view returns (uint160 sqrtPriceX96){
        bytes32 slot0Bytes = poolManager.extsload(keccak256(abi.encode(poolId, POOL_SLOT)));
        assembly {
            // the 160 is the size of the sqrtPriceX96, its a uint160
            // why are we shifting it by 1 bit?
            // 10100000 -> 101000000 -> 10100000 - 1 = 01011111 <<< how are we going to use this as a mask for the slot0 btyes ?
            // and why are we subtracting by one?
            sqrtPriceX96 := and(slot0Bytes, sub(shl(160, 1), 1))
        }
    }

    function getFeeGrowthGlobal(IPoolManager poolManager, PoolId poolId) internal view returns (uint256 feeGrowthGlobal0X128, uint256 feeGrowthGlobal1X128) {
        bytes memory value = poolManager.extsload(bytes32(uint256(keccak256(abi.encode(poolId, POOL_SLOT))) + 1), 2);
        assembly {
            feeGrowthGlobal0X128 := and(mload(add(value, 0x20)), sub(shl(256, 1), 1))
            feeGrowthGlobal1X128 := and(mload(add(value, 0x40)), sub(shl(256, 1), 1))
        }
    }

    function getPositionFeeGrowth(IPoolManager poolManager, PoolId poolId, address owner, int24 tickLower, int24 tickUpper) internal view returns (uint256 feeGrowthInside0LastX128, uint256 feeGrowthInside1LastX128) {
        bytes32 position = keccak256(abi.encodePacked(owner, tickLower, tickUpper));

        // loading three slots to access the entirety of the Position.Info struct
        bytes memory value = poolManager.extsload(
            keccak256(abi.encode(position, uint256(keccak256(abi.encode(poolId, POOL_SLOT))) + POSITIONS_OFFSET)), 3
        );

         // theres a uint128 for liquidity before the fee growth stuff... not sure if we use 30 or 40
        assembly {
            feeGrowthInside0LastX128 := and(mload(add(value, 0x30)), sub(shl(256, 1), 1))
            feeGrowthInside1LastX128 := and(mload(add(value, 0x50)), sub(shl(256, 1), 1))
        }
    }

    function getPositionLiquidity(IPoolManager poolManager, PoolId poolId, address owner, int24 tickLower, int24 tickUpper) internal view returns (uint128 liquidity) {
        bytes32 position = keccak256(abi.encodePacked(owner, tickLower, tickUpper));

        // loading three slots to access the entirety of the Position.Info struct
        bytes memory value = poolManager.extsload(
            keccak256(abi.encode(position, uint256(keccak256(abi.encode(poolId, POOL_SLOT))) + POSITIONS_OFFSET)), 1
        );

         // theres a uint128 for liquidity before the fee growth stuff... 
        assembly {
            liquidity := and(mload(add(value, 0x20)), sub(shl(128, 1), 1))
        }
    }

    function getPosition(IPoolManager poolManager, PoolId poolId, address owner, int24 tickLower, int24 tickUpper) internal view returns (Position.Info memory position) {
        bytes32 position = keccak256(abi.encodePacked(owner, tickLower, tickUpper));

        // loading three slots to access the entirety of the Position.Info struct
        bytes memory value = poolManager.extsload(
            keccak256(abi.encode(position, uint256(keccak256(abi.encode(poolId, POOL_SLOT))) + POSITIONS_OFFSET)), 1
        );

        // and(mload(add(value, 0x20)), shl(128, sub(shl(256, 1), 1))) or 
        // mload(add(value, 0x30)) -- tbh i dont think you can do this

        assembly {
            mstore(position, and(mload(add(value, 0x20)), sub(shl(128, 1), 1)))
            mstore(add(position, 0x20), and(mload(add(value, 0x20)), shl(128, sub(shl(256, 1), 1))))
            mstore(add(position, 0x40), and(mload(add(value, 0x40)), shl(128, sub(shl(256, 1), 1))))
        }
    }

    function getNetLiquidityAtTick(IPoolManager poolManager, PoolId poolId, int24 tick)
        internal
        view
        returns (int128 l)
    {
        bytes32 value = poolManager.extsload(
            keccak256(abi.encode(tick, uint256(keccak256(abi.encode(poolId, POOL_SLOT))) + TICKS_OFFSET))
        );

        assembly {
            l := shr(128, and(value, shl(128, sub(shl(128, 1), 1))))
        }
    }

    function getTickBitmapAtWord(IPoolManager poolManager, PoolId poolId, int16 word)
        internal
        view
        returns (uint256 bm)
    {
        bm = uint256(
            poolManager.extsload(
                keccak256(abi.encode(word, uint256(keccak256(abi.encode(poolId, POOL_SLOT))) + TICK_BITMAP_OFFSET))
            )
        );
    }

    /// @notice Returns the next initialized tick contained in the same word (or adjacent word) as the tick that is either
    /// to the left (less than or equal to) or right (greater than) of the given tick
    /// @param poolManager The mapping in which to compute the next initialized tick
    /// @param tick The starting tick
    /// @param tickSpacing The spacing between usable ticks
    /// @param lte Whether to search for the next initialized tick to the left (less than or equal to the starting tick)
    /// @return next The next initialized or uninitialized tick up to 256 ticks away from the current tick
    /// @return initialized Whether the next tick is initialized, as the function only searches within up to 256 ticks
    function getNextInitializedTickWithinOneWord(
        IPoolManager poolManager,
        PoolId poolId,
        int24 tick,
        int24 tickSpacing,
        bool lte
    ) internal view returns (int24 next, bool initialized) {
        unchecked {
            int24 compressed = tick / tickSpacing;
            if (tick < 0 && tick % tickSpacing != 0) compressed--; // round towards negative infinity

            if (lte) {
                (int16 wordPos, uint8 bitPos) = position(compressed);
                // all the 1s at or to the right of the current bitPos
                uint256 mask = (1 << bitPos) - 1 + (1 << bitPos);
                // uint256 masked = self[wordPos] & mask;
                uint256 masked = getTickBitmapAtWord(poolManager, poolId, wordPos) & mask;

                // if there are no initialized ticks to the right of or at the current tick, return rightmost in the word
                initialized = masked != 0;
                // overflow/underflow is possible, but prevented externally by limiting both tickSpacing and tick
                next = initialized
                    ? (compressed - int24(uint24(bitPos - BitMath.mostSignificantBit(masked)))) * tickSpacing
                    : (compressed - int24(uint24(bitPos))) * tickSpacing;
            } else {
                // start from the word of the next tick, since the current tick state doesn't matter
                (int16 wordPos, uint8 bitPos) = position(compressed + 1);
                // all the 1s at or to the left of the bitPos
                uint256 mask = ~((1 << bitPos) - 1);
                uint256 masked = getTickBitmapAtWord(poolManager, poolId, wordPos) & mask;

                // if there are no initialized ticks to the left of the current tick, return leftmost in the word
                initialized = masked != 0;
                // overflow/underflow is possible, but prevented externally by limiting both tickSpacing and tick
                next = initialized
                    ? (compressed + 1 + int24(uint24(BitMath.leastSignificantBit(masked) - bitPos))) * tickSpacing
                    : (compressed + 1 + int24(uint24(type(uint8).max - bitPos))) * tickSpacing;
            }
        }
    }

    /// @notice Computes the position in the mapping where the initialized bit for a tick lives
    /// @param tick The tick for which to compute the position
    /// @return wordPos The key in the mapping containing the word in which the bit is stored
    /// @return bitPos The bit position in the word where the flag is stored
    function position(int24 tick) private pure returns (int16 wordPos, uint8 bitPos) {
        unchecked {
            wordPos = int16(tick >> 8);
            bitPos = uint8(int8(tick % 256));
        }
    }
}
