// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Descriptor} from "../../src/libraries/Descriptor.sol";
import {Test} from "forge-std/Test.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

contract DescriptorTest is Test {
    function test_feeToPercentString_succeeds() public pure {
        assertEq(Descriptor.feeToPercentString(0x800000), "Dynamic");
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

    function test_addressToString_succeeds() public pure {
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

    function test_escapeSpecialCharacters_succeeds() public pure {
        assertEq(Descriptor.escapeSpecialCharacters(""), "");
        assertEq(Descriptor.escapeSpecialCharacters("a"), "a");
        assertEq(Descriptor.escapeSpecialCharacters("abc"), "abc");
        assertEq(Descriptor.escapeSpecialCharacters("a\"bc"), "a\\\"bc");
        assertEq(Descriptor.escapeSpecialCharacters("a\"b\"c"), "a\\\"b\\\"c");
        assertEq(Descriptor.escapeSpecialCharacters("a\"b\"c\""), "a\\\"b\\\"c\\\"");
        assertEq(Descriptor.escapeSpecialCharacters("\"a\"b\"c\""), "\\\"a\\\"b\\\"c\\\"");
        assertEq(Descriptor.escapeSpecialCharacters("\"a\"b\"c\"\""), "\\\"a\\\"b\\\"c\\\"\\\"");

        assertEq(Descriptor.escapeSpecialCharacters("a\rbc"), "a\\\rbc");
        assertEq(Descriptor.escapeSpecialCharacters("a\nbc"), "a\\\nbc");
        assertEq(Descriptor.escapeSpecialCharacters("a\tbc"), "a\\\tbc");
        assertEq(Descriptor.escapeSpecialCharacters("a\u000cbc"), "a\\\u000cbc");
    }

    function test_tickToDecimalString_withTickSpacing10() public pure {
        int24 tickSpacing = 10;
        int24 minTick = (TickMath.MIN_TICK / tickSpacing) * tickSpacing;
        int24 maxTick = (TickMath.MAX_TICK / tickSpacing) * tickSpacing;
        assertEq(Descriptor.tickToDecimalString(minTick, tickSpacing, 18, 18, false), "MIN");
        assertEq(Descriptor.tickToDecimalString(maxTick, tickSpacing, 18, 18, false), "MAX");
        assertEq(Descriptor.tickToDecimalString(1, tickSpacing, 18, 18, false), "1.0001");
        int24 otherMinTick = (TickMath.MIN_TICK / 60) * 60;
        assertEq(
            Descriptor.tickToDecimalString(otherMinTick, tickSpacing, 18, 18, false),
            "0.0000000000000000000000000000000000000029387"
        );
    }

    function test_tickToDecimalString_withTickSpacing60() public pure {
        int24 tickSpacing = 60;
        int24 minTick = (TickMath.MIN_TICK / tickSpacing) * tickSpacing;
        int24 maxTick = (TickMath.MAX_TICK / tickSpacing) * tickSpacing;
        assertEq(Descriptor.tickToDecimalString(minTick, tickSpacing, 18, 18, false), "MIN");
        assertEq(Descriptor.tickToDecimalString(maxTick, tickSpacing, 18, 18, false), "MAX");
        assertEq(Descriptor.tickToDecimalString(-1, tickSpacing, 18, 18, false), "0.99990");
        int24 otherMinTick = (TickMath.MIN_TICK / 200) * 200;
        assertEq(
            Descriptor.tickToDecimalString(otherMinTick, tickSpacing, 18, 18, false),
            "0.0000000000000000000000000000000000000029387"
        );
    }

    function test_tickToDecimalString_withTickSpacing200() public pure {
        int24 tickSpacing = 200;
        int24 minTick = (TickMath.MIN_TICK / tickSpacing) * tickSpacing;
        int24 maxTick = (TickMath.MAX_TICK / tickSpacing) * tickSpacing;
        assertEq(Descriptor.tickToDecimalString(minTick, tickSpacing, 18, 18, false), "MIN");
        assertEq(Descriptor.tickToDecimalString(maxTick, tickSpacing, 18, 18, false), "MAX");
        assertEq(Descriptor.tickToDecimalString(0, tickSpacing, 18, 18, false), "1.0000");
        int24 otherMinTick = (TickMath.MIN_TICK / 60) * 60;
        assertEq(
            Descriptor.tickToDecimalString(otherMinTick, tickSpacing, 18, 18, false),
            "0.0000000000000000000000000000000000000029387"
        );
    }

    function test_tickToDecimalString_ratio_returnsInverseMediumNumbers() public pure {
        int24 tickSpacing = 200;
        assertEq(Descriptor.tickToDecimalString(10, tickSpacing, 18, 18, false), "1.0010");
        assertEq(Descriptor.tickToDecimalString(10, tickSpacing, 18, 18, true), "0.99900");
    }

    function test_tickToDecimalString_ratio_returnsInverseLargeNumbers() public pure {
        int24 tickSpacing = 200;
        assertEq(Descriptor.tickToDecimalString(487272, tickSpacing, 18, 18, false), "1448400000000000000000");
        assertEq(Descriptor.tickToDecimalString(487272, tickSpacing, 18, 18, true), "0.00000000000000000000069041");
    }

    function test_tickToDecimalString_ratio_returnsInverseSmallNumbers() public pure {
        int24 tickSpacing = 200;
        assertEq(Descriptor.tickToDecimalString(-387272, tickSpacing, 18, 18, false), "0.000000000000000015200");
        assertEq(Descriptor.tickToDecimalString(-387272, tickSpacing, 18, 18, true), "65791000000000000");
    }

    function test_tickToDecimalString_differentDecimals() public pure {
        int24 tickSpacing = 200;
        assertEq(Descriptor.tickToDecimalString(1000, tickSpacing, 18, 18, true), "0.90484");
        assertEq(Descriptor.tickToDecimalString(1000, tickSpacing, 18, 10, true), "90484000");
        assertEq(Descriptor.tickToDecimalString(1000, tickSpacing, 10, 18, true), "0.0000000090484");
    }

    function test_fixedPointToDecimalString() public pure {
        assertEq(
            Descriptor.fixedPointToDecimalString(1457647476727839560029885420909913413788472405159, 18, 18),
            "338490000000000000000000000000000000000"
        );
        assertEq(
            Descriptor.fixedPointToDecimalString(4025149349925610116743993887520032712, 18, 18), "2581100000000000"
        );
        assertEq(Descriptor.fixedPointToDecimalString(3329657202331788924044422905302854, 18, 18), "1766200000");
        assertEq(Descriptor.fixedPointToDecimalString(16241966553695418990605751641065, 18, 18), "42026");
        assertEq(Descriptor.fixedPointToDecimalString(2754475062069337566441091812235, 18, 18), "1208.7");
        assertEq(Descriptor.fixedPointToDecimalString(871041495427277622831427623669, 18, 18), "120.87");
        assertEq(Descriptor.fixedPointToDecimalString(275447506206933756644109181223, 18, 18), "12.087");

        assertEq(Descriptor.fixedPointToDecimalString(88028870788706913884596530851, 18, 18), "1.2345");
        assertEq(Descriptor.fixedPointToDecimalString(79228162514264337593543950336, 18, 18), "1.0000");
        assertEq(Descriptor.fixedPointToDecimalString(27837173154497669652482281089, 18, 18), "0.12345");
        assertEq(Descriptor.fixedPointToDecimalString(1559426812423768092342, 18, 18), "0.00000000000000038741");
        assertEq(Descriptor.fixedPointToDecimalString(74532606916587, 18, 18), "0.00000000000000000000000000000088498");
        assertEq(
            Descriptor.fixedPointToDecimalString(4947797163, 18, 18), "0.0000000000000000000000000000000000000029387"
        );

        assertEq(Descriptor.fixedPointToDecimalString(79228162514264337593543950336, 18, 16), "100.00");
        assertEq(Descriptor.fixedPointToDecimalString(250541448375047931186413801569, 18, 17), "100.00");
        assertEq(Descriptor.fixedPointToDecimalString(79228162514264337593543950336, 24, 5), "1.0000");

        assertEq(Descriptor.fixedPointToDecimalString(79228162514264337593543950336, 10, 18), "0.000000010000");
        assertEq(Descriptor.fixedPointToDecimalString(79228162514264337593543950336, 7, 18), "0.000000000010000");
    }
}
