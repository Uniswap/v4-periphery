// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "forge-std/StdError.sol";
import {BipsLibrary} from "../../src/libraries/BipsLibrary.sol";

contract PositionConfigTest is Test {
    using BipsLibrary for uint256;

    function test_fuzz_calculatePortion(uint256 amount, uint256 bips) public {
        amount = bound(amount, 0, uint256(type(uint128).max));
        if (bips > BipsLibrary.BIPS_BASE) {
            vm.expectRevert(BipsLibrary.InvalidBips.selector);
            amount.calculatePortion(bips);
        } else {
            assertEq(amount.calculatePortion(bips), amount * bips / BipsLibrary.BIPS_BASE);
        }
    }
}
