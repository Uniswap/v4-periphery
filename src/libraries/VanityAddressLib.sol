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
        // Requirement: The first nonzero nibble must be 4
        // 10 points for every leading 0 nibble
        // 40 points if the first 4 is followed by 3 more 4s
        // 20 points if the first nibble after the 4 4s is NOT a 4
        // 20 points if the last 4 nibbles are 4s
        // 1 point for every 4
        bytes20 addrBytes = bytes20(addr);

        bool startingZeros = true;
        bool startingFours = true;
        bool firstFour = true;
        uint8 fourCounts; // counter for the number of 4s
        // iterate over the nibbles of the address
        for (uint256 i = 0; i < addrBytes.length * 2; i++) {
            uint8 currentNibble;
            if (i % 2 == 0) {
                // Get the higher nibble of the byte
                currentNibble = uint8(addrBytes[i / 2] >> 4);
            } else {
                // Get the lower nibble of the byte
                currentNibble = uint8(addrBytes[i / 2] & 0x0F);
            }

            // leading 0s
            if (startingZeros && currentNibble == 0) {
                calculatedScore += 10;
                continue;
            } else {
                startingZeros = false;
            }

            // leading 4s
            if (startingFours) {
                // If the first nonzero nibble is not 4, the score is an automatic 0
                if (firstFour && currentNibble != 4) {
                    return 0;
                }

                if (currentNibble == 4) {
                    fourCounts += 1;
                    if (fourCounts == 4) {
                        calculatedScore += 40;
                        // If the leading 4 4s are also the last 4 nibbles, add 20 points
                        if (i == addrBytes.length * 2 - 1) {
                            calculatedScore += 20;
                        }
                    }
                } else {
                    // If the first nibble after the 4 4s is not a 4, add 20 points
                    if (fourCounts == 4) {
                        calculatedScore += 20;
                    }
                    startingFours = false;
                }
                firstFour = false;
            }

            // count each 4 nibble separately
            if (currentNibble == 4) {
                calculatedScore += 1;
            }
        }

        // If the last 4 nibbles are 4s, add 20 points
        if (addrBytes[18] & 0xFF == 0x44 && addrBytes[19] & 0xFF == 0x44) {
            calculatedScore += 20;
        }
    }
}
