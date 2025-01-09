// SPDX-License-Identifier: MIT
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
    /// @dev Scoring rules:
    ///    Requirement: The first nonzero nibble must be 4
    ///    10 points for every leading 0 nibble
    ///    40 points if the first 4 is followed by 3 more 4s
    ///    20 points if the first nibble after the 4 4s is NOT a 4
    ///    20 points if the last 4 nibbles are 4s
    ///    1 point for every 4
    /// @param addr The address to score
    /// @return calculatedScore The vanity score of the address
    function score(address addr) internal pure returns (uint256 calculatedScore) {
        // convert the address to bytes for easier parsing
        bytes20 addrBytes = bytes20(addr);

        unchecked {
            // 10 points per leading zero nibble
            uint256 leadingZeroCount = getLeadingNibbleCount(addrBytes, 0, 0);
            calculatedScore += (leadingZeroCount * 10);

            // special handling for 4s immediately after leading 0s
            uint256 leadingFourCount = getLeadingNibbleCount(addrBytes, leadingZeroCount, 4);
            // If the first nonzero nibble is not 4, return 0
            if (leadingFourCount == 0) {
                return 0;
            } else if (leadingFourCount == 4) {
                // 60 points if exactly 4 4s
                calculatedScore += 60;
            } else if (leadingFourCount > 4) {
                // 40 points if more than 4 4s
                calculatedScore += 40;
            }

            // handling for remaining nibbles
            for (uint256 i = 0; i < addrBytes.length * 2; i++) {
                uint8 currentNibble = getNibble(addrBytes, i);

                // 1 extra point for any 4 nibbles
                if (currentNibble == 4) {
                    calculatedScore += 1;
                }
            }

            // If the last 4 nibbles are 4s, add 20 points
            if (addrBytes[18] == 0x44 && addrBytes[19] == 0x44) {
                calculatedScore += 20;
            }
        }
    }

    /// @notice Returns the number of leading nibbles in an address that match a given value
    /// @param addrBytes The address to count the leading zero nibbles in
    function getLeadingNibbleCount(bytes20 addrBytes, uint256 startIndex, uint8 comparison)
        internal
        pure
        returns (uint256 count)
    {
        if (startIndex >= addrBytes.length * 2) {
            return count;
        }

        for (uint256 i = startIndex; i < addrBytes.length * 2; i++) {
            uint8 currentNibble = getNibble(addrBytes, i);
            if (currentNibble != comparison) {
                return count;
            }
            count += 1;
        }
    }

    /// @notice Returns the nibble at a given index in an address
    /// @param input The address to get the nibble from
    /// @param nibbleIndex The index of the nibble to get
    function getNibble(bytes20 input, uint256 nibbleIndex) internal pure returns (uint8 currentNibble) {
        uint8 currByte = uint8(input[nibbleIndex / 2]);
        if (nibbleIndex % 2 == 0) {
            // Get the higher nibble of the byte
            currentNibble = currByte >> 4;
        } else {
            // Get the lower nibble of the byte
            currentNibble = currByte & 0x0F;
        }
    }
}
