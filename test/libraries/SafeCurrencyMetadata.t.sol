// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {SafeCurrencyMetadata} from "../../src/libraries/SafeCurrencyMetadata.sol";
import {AddressStringUtil} from "../../src/libraries/AddressStringUtil.sol";

contract ValidStringToken {
    function symbol() external pure returns (string memory) {
        return "TEST";
    }
}

contract Bytes32Token {
    function symbol() external pure returns (bytes32) {
        return bytes32("MKR");
    }
}

contract MalformedOffsetToken {
    // Returns 96 bytes where Word 0 (offset) is 0x80 (128), which is out of bounds for 96 bytes
    fallback() external {
        bytes memory malformedData =
            abi.encodePacked(bytes32(uint256(0x80)), bytes32(uint256(10)), bytes32(uint256(0x123456)));
        assembly {
            return(add(malformedData, 0x20), mload(malformedData))
        }
    }
}

contract OversizedLengthToken {
    // Returns 96 bytes where offset is 0x20, but length is 100 (> 96 - 64 = 32)
    fallback() external {
        bytes memory malformedData =
            abi.encodePacked(bytes32(uint256(0x20)), bytes32(uint256(100)), bytes32(uint256(0x123456)));
        assembly {
            return(add(malformedData, 0x20), mload(malformedData))
        }
    }
}

contract NonStandardRawBytesToken {
    // Returns 65 raw bytes (exceeds 64 bytes but offset is not 0x20)
    fallback() external {
        bytes memory rawData = new bytes(65);
        for (uint256 i = 0; i < 65; i++) {
            rawData[i] = bytes1(uint8(i + 1));
        }
        assembly {
            return(add(rawData, 0x20), 65)
        }
    }
}

contract SafeCurrencyMetadataTest is Test {
    function test_truncateSymbol_succeeds() public pure {
        // 12 characters
        assertEq(SafeCurrencyMetadata.truncateSymbol("123456789012"), "123456789012");
        // 13 characters
        assertEq(SafeCurrencyMetadata.truncateSymbol("1234567890123"), "123456789012");
        // 14 characters
        assertEq(SafeCurrencyMetadata.truncateSymbol("12345678901234"), "123456789012");
    }

    function test_currencySymbol_validString_succeeds() public {
        ValidStringToken token = new ValidStringToken();
        string memory sym = SafeCurrencyMetadata.currencySymbol(address(token), "ETH");
        assertEq(sym, "TEST");
    }

    function test_currencySymbol_bytes32_succeeds() public {
        Bytes32Token token = new Bytes32Token();
        string memory sym = SafeCurrencyMetadata.currencySymbol(address(token), "ETH");
        assertEq(sym, "MKR");
    }

    function test_currencySymbol_malformedOffset_fallsBackToAddress() public {
        MalformedOffsetToken token = new MalformedOffsetToken();
        string memory expectedFallback = AddressStringUtil.toAsciiString(address(token), 6);
        string memory sym = SafeCurrencyMetadata.currencySymbol(address(token), "ETH");
        assertEq(sym, expectedFallback);
    }

    function test_currencySymbol_oversizedLength_fallsBackToAddress() public {
        OversizedLengthToken token = new OversizedLengthToken();
        string memory expectedFallback = AddressStringUtil.toAsciiString(address(token), 6);
        string memory sym = SafeCurrencyMetadata.currencySymbol(address(token), "ETH");
        assertEq(sym, expectedFallback);
    }

    function test_currencySymbol_nonStandardRawBytes_fallsBackToAddress() public {
        NonStandardRawBytesToken token = new NonStandardRawBytesToken();
        string memory expectedFallback = AddressStringUtil.toAsciiString(address(token), 6);
        string memory sym = SafeCurrencyMetadata.currencySymbol(address(token), "ETH");
        assertEq(sym, expectedFallback);
    }
}
