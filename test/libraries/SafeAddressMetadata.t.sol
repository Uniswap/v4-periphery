// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {SafeAddressMetadata} from "../../src/libraries/SafeAddressMetadata.sol";

contract SafeAddressMetadataTest is Test {
    function test_truncateSymbol_succeeds() public pure {
        // 12 characters
        assertEq(SafeAddressMetadata.truncateSymbol("123456789012"), "123456789012");
        // 13 characters
        assertEq(SafeAddressMetadata.truncateSymbol("1234567890123"), "123456789012");
        // 14 characters
        assertEq(SafeAddressMetadata.truncateSymbol("12345678901234"), "123456789012");
    }
}
