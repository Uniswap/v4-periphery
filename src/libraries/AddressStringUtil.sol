// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @title AddressStringUtil
/// @notice provides utility functions for converting addresses to strings
/// @dev Reference: https://github.com/Uniswap/solidity-lib/blob/master/contracts/libraries/AddressStringUtil.sol
library AddressStringUtil {
    error InvalidAddressLength(uint256 len);

    /// @notice Converts an address to the uppercase hex string, extracting only len bytes (up to 20, multiple of 2)
    /// @param addr the address to convert
    /// @param len the number of bytes to extract
    /// @return the hex string
    function toAsciiString(address addr, uint256 len) internal pure returns (string memory) {
        if (!(len % 2 == 0 && len > 0 && len <= 40)) {
            revert InvalidAddressLength(len);
        }

        bytes memory s = new bytes(len);
        uint256 addrNum = uint256(uint160(addr));
        for (uint256 i = 0; i < len / 2; i++) {
            // shift right and truncate all but the least significant byte to extract the byte at position 19-i
            uint8 b = uint8(addrNum >> (8 * (19 - i)));
            // first hex character is the most significant 4 bits
            uint8 hi = b >> 4;
            // second hex character is the least significant 4 bits
            uint8 lo = b - (hi << 4);
            s[2 * i] = char(hi);
            s[2 * i + 1] = char(lo);
        }
        return string(s);
    }

    /// @notice Converts a value into is corresponding ASCII character for the hex representation
    // hi and lo are only 4 bits and between 0 and 16
    // uses upper case for the characters
    /// @param b the value to convert
    /// @return c the ASCII character
    function char(uint8 b) private pure returns (bytes1 c) {
        if (b < 10) {
            return bytes1(b + 0x30);
        } else {
            return bytes1(b + 0x37);
        }
    }
}
