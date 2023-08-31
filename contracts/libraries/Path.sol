// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.8.20;

import './BytesLib.sol';
import {PoolKey} from "@uniswap/v4-core/contracts/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/contracts/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/contracts/interfaces/IHooks.sol";

/// @title Functions for manipulating path data for multihop swaps
library Path {
    using BytesLib for bytes;

    /// @dev The length of the bytes encoded address
    uint256 private constant ADDR_SIZE = 20;
    /// @dev The length of the bytes encoded fee
    uint256 private constant FEE_SIZE = 3;
    /// @dev The length of the bytes encoded fee
    uint256 private constant TICK_SPACING_SIZE = 3;

    /// @dev The offset of a single token address, hooks address, fee, and tickspacing
    uint256 private constant NEXT_OFFSET = ADDR_SIZE * 2 + FEE_SIZE + TICK_SPACING_SIZE;
    /// @dev The offset of an encoded pool key
    uint256 private constant POP_OFFSET = NEXT_OFFSET + ADDR_SIZE;
    /// @dev The minimum length of an encoding that contains 2 or more pools
    uint256 private constant MULTIPLE_POOLS_MIN_LENGTH = POP_OFFSET + NEXT_OFFSET;

    /// @notice Returns true if the path contains two or more pools
    /// @param path The encoded swap path
    /// @return True if path contains two or more pools, otherwise false
    function isFinalSwap(bytes memory path) internal pure returns (bool) {
        return path.length < MULTIPLE_POOLS_MIN_LENGTH;
    }

    /// @notice Returns the number of pools in the path
    /// @param path The encoded swap path
    /// @return The number of pools in the path
    function numPools(bytes memory path) internal pure returns (uint256) {
        // Ignore the first token address. From then on every fee and token offset indicates a pool.
        return ((path.length - ADDR_SIZE) / NEXT_OFFSET);
    }

    /// @notice Decodes the first pool in path
    /// @param path The bytes encoded swap path
    /// @return poolKey The first poolKey in the given path
    /// @return zeroForOne true if we're trading currency0 for currency1
    function decodeFirstPoolKeyAndSwapDirection(bytes memory path)
        internal
        pure
        returns (PoolKey memory poolKey, bool zeroForOne)
    {
        Currency currencyA = Currency.wrap(path.toAddress(0));
        Currency currencyB = Currency.wrap(path.toAddress(NEXT_OFFSET));
        zeroForOne = currencyA < currencyB;

        (poolKey.currency0, poolKey.currency1) = zeroForOne ? (currencyA, currencyB) : (currencyB, currencyA);
        poolKey.fee = path.toUint24(ADDR_SIZE);
        poolKey.tickSpacing = int24(path.toUint24(ADDR_SIZE + FEE_SIZE));
        poolKey.hooks = IHooks(path.toAddress(ADDR_SIZE + FEE_SIZE + TICK_SPACING_SIZE));
    }

    /// @notice Gets the segment corresponding to the first pool in the path
    /// @param path The bytes encoded swap path
    /// @return The segment containing all data necessary to target the first pool in the path
    function getFirstPool(bytes memory path) internal pure returns (bytes memory) {
        return path.slice(0, POP_OFFSET);
    }

    /// @notice Skips a token + fee element from the buffer and returns the remainder
    /// @param path The swap path
    /// @return The remaining token + fee elements in the path
    function skipToken(bytes memory path) internal pure returns (bytes memory) {
        return path.slice(NEXT_OFFSET, path.length - NEXT_OFFSET);
    }
}
