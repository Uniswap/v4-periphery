// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

/// @title VanityAddressLib
/// @notice A library to score addresses based on their vanity
library VanityAddressLib {
    /// @notice Compares two addresses and returns true if the first address has a better vanity score
    /// @param first The first address to compare
    /// @param second The second address to compare
    /// @return better True if the first address has a better vanity score
    function betterThan(address first, address second) internal pure returns (bool better) {
        return score(first) > score(second);
    }

    /// @notice Scores an address based on its vanity
    /// @param addr The address to score
    /// @return calculatedScore The vanity score of the address
    function score(address addr) internal pure returns (uint256 calculatedScore) {
        // 10 points for every leading 0
        // 3 points for every leading 4
        // 1 point for every 4 after that
        bytes20 addrBytes = bytes20(addr);

        bool startingZeros = true;
        bool startingFours = true;
        // iterate over the bytes of the address
        for (uint256 i = 0; i < 20; i++) {
            if (startingZeros && addrBytes[i] == 0x00) {
                calculatedScore += 20;
                continue;
            } else if (startingZeros && (addrBytes[i] & 0xF0) == 0x00) {
                calculatedScore += 10;
                startingZeros = false;
            } else {
                startingZeros = false;
            }
            if (startingFours && addrBytes[i] == 0x44) {
                calculatedScore += 6;
                continue;
            } else if (startingFours && (addrBytes[i] & 0xF0 == 0x40) || (addrBytes[i] & 0xFF == 0x04)) {
                calculatedScore += 3;
                startingFours = false;
                continue;
            } else {
                startingFours = false;
            }

            if (!startingZeros && !startingFours) {
                // count each nibble separately
                if (addrBytes[i] & 0xFF == 0x44) {
                    calculatedScore += 2;
                } else if (addrBytes[i] & 0x0F == 0x04) {
                    calculatedScore += 1;
                } else if (addrBytes[i] & 0xF0 == 0x40) {
                    calculatedScore += 1;
                }
            }
        }
    }
}
