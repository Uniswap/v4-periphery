// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "forge-std/StdError.sol";
import {BipsLibrary} from "../../src/libraries/BipsLibrary.sol";

contract PositionConfigTest is Test {
    using BipsLibrary for uint256;

    function test_fuzz_calculatePortion(uint256 amount, uint256 bips) public {
        amount = bound(amount, 0, uint256(type(uint128).max));
        if (bips > BipsLibrary.BPS_DENOMINATOR) {
            vm.expectRevert(BipsLibrary.InvalidBips.selector);
            amount.calculatePortion(bips);
        } else {
            assertEq(amount.calculatePortion(bips), amount * bips / BipsLibrary.BPS_DENOMINATOR);
        }
    }

    function test_fuzz_gasLimitt(uint256 bips) public {
        if (bips > BipsLibrary.BPS_DENOMINATOR) {
            vm.expectRevert(BipsLibrary.InvalidBips.selector);
            block.gaslimit.calculatePortion(bips);
        } else {
            assertEq(block.gaslimit.calculatePortion(bips), block.gaslimit * bips / BipsLibrary.BPS_DENOMINATOR);
        }
    }

    function test_gasLimit_100_percent() public view {
        assertEq(block.gaslimit, block.gaslimit.calculatePortion(10_000));
    }

    function test_gasLimit_1_percent() public view {
        /// 100 bps = 1%
        // 1% of 3_000_000_000 is 30_000_000
        assertEq(30_000_000, block.gaslimit.calculatePortion(100));
    }

    function test_gasLimit_1BP() public view {
        /// 1bp is 0.01%
        assertEq(300_000, block.gaslimit.calculatePortion(1));
    }
}
