// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {GasLimitCalculator} from "../../src/libraries/GasLimitCalculator.sol";

contract GasLimitCalculatorTest is Test {
    function test_gasLimit_100_percent() public view {
        assertEq(block.gaslimit, GasLimitCalculator.toGasLimit(10_000));
    }

    function test_gasLimit_1_percent() public view {
        /// 100 bps = 1%
        // 1% of 3_000_000_000 is 30_000_000
        assertEq(30_000_000, GasLimitCalculator.toGasLimit(100));
    }

    function test_gasLimit_1BP() public view {
        /// 1bp is 0.01%
        assertEq(300_000, GasLimitCalculator.toGasLimit(1));
    }
}
