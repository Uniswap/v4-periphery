// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

// A PositionConfig is the input for creating and modifying a Position in core, whose truncated hash is set per tokenId
struct PositionConfig {
    PoolKey poolKey;
    int24 tickLower;
    int24 tickUpper;
}

/// @notice Library to calculate the PositionConfigId from the PositionConfig struct
library PositionConfigLibrary {
    function toId(PositionConfig calldata config) internal pure returns (bytes32 id) {
        // id = keccak256(abi.encodePacked(currency0, currency1, fee, tickSpacing, hooks, tickLower, tickUpper))) >> 1
        assembly ("memory-safe") {
            let fmp := mload(0x40)
            mstore(add(fmp, 0x34), calldataload(add(config, 0xc0))) // tickUpper: [0x51, 0x54)
            mstore(add(fmp, 0x31), calldataload(add(config, 0xa0))) // tickLower: [0x4E, 0x51)
            mstore(add(fmp, 0x2E), calldataload(add(config, 0x80))) // hooks: [0x3A, 0x4E)
            mstore(add(fmp, 0x1A), calldataload(add(config, 0x60))) // tickSpacing: [0x37, 0x3A)
            mstore(add(fmp, 0x17), calldataload(add(config, 0x40))) // fee: [0x34, 0x37)
            mstore(add(fmp, 0x14), calldataload(add(config, 0x20))) // currency1: [0x20, 0x34)
            mstore(fmp, calldataload(config)) // currency0: [0x0c, 0x20)

            id := shr(1, keccak256(add(fmp, 0x0c), 0x48)) // len is 72 bytes, truncate lower bit of the hash

            // now clean the memory we used
            mstore(add(fmp, 0x40), 0) // fmp+0x40 held hooks (14 bytes), tickLower, tickUpper
            mstore(add(fmp, 0x20), 0) // fmp+0x20 held currency1, fee, tickSpacing, hooks (6 bytes)
            mstore(fmp, 0) // fmp held currency0
        }
    }
}
