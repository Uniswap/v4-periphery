// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @title HexStrings
/// @notice Provides function for converting numbers to hexadecimal strings
/// @dev Reference: https://github.com/Uniswap/v3-periphery/blob/main/contracts/libraries/HexStrings.sol
library HexStrings {
    bytes16 internal constant ALPHABET = "0123456789abcdef";

    /// @notice Convert a number to a hex string without the '0x' prefix with a fixed length
    /// @param value The number to convert
    /// @param length The length of the output string, starting from the last character of the string
    /// @return The hex string
    function toHexStringNoPrefix(uint256 value, uint256 length) internal pure returns (string memory) {
        bytes memory buffer = new bytes(2 * length);
        for (uint256 i = buffer.length; i > 0; i--) {
            buffer[i - 1] = ALPHABET[value & 0xf];
            value >>= 4;
        }
        return string(buffer);
    }
}
