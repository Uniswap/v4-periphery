// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Descriptor} from "../../src/libraries/Descriptor.sol";
import {Test} from "forge-std/Test.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

contract DescriptorTest is Test {
    function test_feeToPercentString_succeeds() public {
        assertEq(Descriptor.feeToPercentString(0), "0%");
        assertEq(Descriptor.feeToPercentString(1), "0.0001%");
        assertEq(Descriptor.feeToPercentString(30), "0.003%");
        assertEq(Descriptor.feeToPercentString(33), "0.0033%");
        assertEq(Descriptor.feeToPercentString(500), "0.05%");
        assertEq(Descriptor.feeToPercentString(2500), "0.25%");
        assertEq(Descriptor.feeToPercentString(3000), "0.3%");
        assertEq(Descriptor.feeToPercentString(10000), "1%");
        assertEq(Descriptor.feeToPercentString(17000), "1.7%");
        assertEq(Descriptor.feeToPercentString(100000), "10%");
        assertEq(Descriptor.feeToPercentString(150000), "15%");
        assertEq(Descriptor.feeToPercentString(102000), "10.2%");
        assertEq(Descriptor.feeToPercentString(1000000), "100%");
        assertEq(Descriptor.feeToPercentString(1005000), "100.5%");
        assertEq(Descriptor.feeToPercentString(10000000), "1000%");
        assertEq(Descriptor.feeToPercentString(12300000), "1230%");
    }

    function test_addressToString_succeeds() public {
        assertEq(Descriptor.addressToString(address(0)), "0x0000000000000000000000000000000000000000");
        assertEq(Descriptor.addressToString(address(1)), "0x0000000000000000000000000000000000000001");
        assertEq(
            Descriptor.addressToString(0x1111111111111111111111111111111111111111),
            "0x1111111111111111111111111111111111111111"
        );
        assertEq(
            Descriptor.addressToString(0x1234AbcdEf1234abcDef1234aBCdEF1234ABCDEF),
            "0x1234abcdef1234abcdef1234abcdef1234abcdef"
        );
    }

    function test_escapeQuotes_succeeds() public {
        assertEq(Descriptor.escapeQuotes(""), "");
        assertEq(Descriptor.escapeQuotes("a"), "a");
        assertEq(Descriptor.escapeQuotes("abc"), "abc");
        assertEq(Descriptor.escapeQuotes("a\"bc"), "a\\\"bc");
        assertEq(Descriptor.escapeQuotes("a\"b\"c"), "a\\\"b\\\"c");
        assertEq(Descriptor.escapeQuotes("a\"b\"c\""), "a\\\"b\\\"c\\\"");
        assertEq(Descriptor.escapeQuotes("\"a\"b\"c\""), "\\\"a\\\"b\\\"c\\\"");
        assertEq(Descriptor.escapeQuotes("\"a\"b\"c\"\""), "\\\"a\\\"b\\\"c\\\"\\\"");
    }

    function test_tickToDecimalString_withTickSpacing10() public {
        int24 tickSpacing = 10;
        int24 minTick = (TickMath.MIN_TICK / tickSpacing) * tickSpacing;
        int24 maxTick = (TickMath.MAX_TICK / tickSpacing) * tickSpacing;
        assertEq(Descriptor.tickToDecimalString(minTick, tickSpacing, 18, 18, false), "MIN");
        assertEq(Descriptor.tickToDecimalString(maxTick, tickSpacing, 18, 18, false), "MAX");
        assertEq(Descriptor.tickToDecimalString(1, tickSpacing, 18, 18, false), "1.0001");
        int24 otherMinTick = (TickMath.MIN_TICK / 60) * 60;
        assertEq(Descriptor.tickToDecimalString(otherMinTick, tickSpacing, 18, 18, false), "0.0000000000000000000000000000000000000029387");
    }

    function test_tickToDecimalString_withTickSpacing60() public {
        int24 tickSpacing = 60;
        int24 minTick = (TickMath.MIN_TICK / tickSpacing) * tickSpacing;
        int24 maxTick = (TickMath.MAX_TICK / tickSpacing) * tickSpacing;
        assertEq(Descriptor.tickToDecimalString(minTick, tickSpacing, 18, 18, false), "MIN");
        assertEq(Descriptor.tickToDecimalString(maxTick, tickSpacing, 18, 18, false), "MAX");
        assertEq(Descriptor.tickToDecimalString(-1, tickSpacing, 18, 18, false), "0.99990");
        int24 otherMinTick = (TickMath.MIN_TICK / 200) * 200;
        assertEq(Descriptor.tickToDecimalString(otherMinTick, tickSpacing, 18, 18, false), "0.0000000000000000000000000000000000000029387");
    }

    function test_tickToDecimalString_withTickSpacing200() public {
        int24 tickSpacing = 200;
        int24 minTick = (TickMath.MIN_TICK / tickSpacing) * tickSpacing;
        int24 maxTick = (TickMath.MAX_TICK / tickSpacing) * tickSpacing;
        assertEq(Descriptor.tickToDecimalString(minTick, tickSpacing, 18, 18, false), "MIN");
        assertEq(Descriptor.tickToDecimalString(maxTick, tickSpacing, 18, 18, false), "MAX");
        assertEq(Descriptor.tickToDecimalString(0, tickSpacing, 18, 18, false), "1.0000");
        int24 otherMinTick = (TickMath.MIN_TICK / 60) * 60;
        assertEq(Descriptor.tickToDecimalString(otherMinTick, tickSpacing, 18, 18, false), "0.0000000000000000000000000000000000000029387");
    }

    function test_tickToDecimalString_ratio_returnsInverseMediumNumbers() public {
        int24 tickSpacing = 200;
        assertEq(Descriptor.tickToDecimalString(10, tickSpacing, 18, 18, false), "1.0010");
        assertEq(Descriptor.tickToDecimalString(10, tickSpacing, 18, 18, true), "0.99900");
    }

    function test_tickToDecimalString_ratio_returnsInverseLargeNumbers() public {
        int24 tickSpacing = 200;
        assertEq(Descriptor.tickToDecimalString(487272, tickSpacing, 18, 18, false), "1448400000000000000000");
        assertEq(Descriptor.tickToDecimalString(487272, tickSpacing, 18, 18, true), "0.00000000000000000000069041");
    }

    function test_tickToDecimalString_ratio_returnsInverseSmallNumbers() public {
        int24 tickSpacing = 200;
        assertEq(Descriptor.tickToDecimalString(-387272, tickSpacing, 18, 18, false), "0.000000000000000015200");
        assertEq(Descriptor.tickToDecimalString(-387272, tickSpacing, 18, 18, true), "65791000000000000");
    }

    function test_tickToDecimalString_differentDecimals() public {
        int24 tickSpacing = 200;
        assertEq(Descriptor.tickToDecimalString(1000, tickSpacing, 18, 18, true), "0.90484");
        assertEq(Descriptor.tickToDecimalString(1000, tickSpacing, 18, 10, true), "90484000");
        assertEq(Descriptor.tickToDecimalString(1000, tickSpacing, 10, 18, true), "0.0000000090484");
    }

    function test_fixedPointToDecimalString_succeeds() public {

    }
 
}
