// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {Market} from "../../src/types/Market.sol";
import {EnumerableMarketKeys} from "../../src/types/EnumerableMarketKeys.sol";

contract EnumerableMarketKeysTest is Test {
    EnumerableMarketKeys internal keys;

    function _c(uint160 a) internal pure returns (Currency) {
        return Currency.wrap(address(a));
    }

    function test_add_isIdempotent_andCounts() public {
        keys.add(_c(1), _c(2));
        keys.add(_c(1), _c(2)); // idempotent: no duplicate
        keys.add(_c(3), _c(4));
        assertEq(keys.count(), 2);
        assertTrue(keys.has(_c(1), _c(2)));
        assertTrue(keys.has(_c(3), _c(4)));
        assertFalse(keys.has(_c(5), _c(6)));
    }

    function test_add_allowsZeroPair_primitiveHoldsNoPolicy() public {
        // the primitive itself refuses nothing; the all-zero policy lives in the embedding types
        keys.add(_c(0), _c(0));
        assertTrue(keys.has(_c(0), _c(0)));
        assertEq(keys.count(), 1);
    }

    function test_remove_absent_isNoOp() public {
        keys.add(_c(1), _c(2));
        keys.remove(_c(9), _c(9));
        assertEq(keys.count(), 1);
        assertTrue(keys.has(_c(1), _c(2)));
    }

    function test_remove_middle_swapsLastIntoSlot() public {
        keys.add(_c(1), _c(2));
        keys.add(_c(3), _c(4));
        keys.add(_c(5), _c(6));
        keys.remove(_c(3), _c(4));
        assertEq(keys.count(), 2);
        assertFalse(keys.has(_c(3), _c(4)));
        // the last member (5,6) swapped into the freed slot
        Market[] memory all = keys.page(0, 10);
        assertEq(all.length, 2);
        assertEq(Currency.unwrap(all[0].collateral), address(1));
        assertEq(Currency.unwrap(all[1].collateral), address(5));
    }

    function test_remove_last_pops() public {
        keys.add(_c(1), _c(2));
        keys.add(_c(3), _c(4));
        keys.remove(_c(3), _c(4));
        assertEq(keys.count(), 1);
        assertTrue(keys.has(_c(1), _c(2)));
        assertFalse(keys.has(_c(3), _c(4)));
    }

    function test_remove_only_emptiesSet() public {
        keys.add(_c(1), _c(2));
        keys.remove(_c(1), _c(2));
        assertEq(keys.count(), 0);
        assertFalse(keys.has(_c(1), _c(2)));
        assertEq(keys.page(0, 10).length, 0);
    }

    function test_reAdd_afterRemove() public {
        keys.add(_c(1), _c(2));
        keys.remove(_c(1), _c(2));
        keys.add(_c(1), _c(2));
        assertEq(keys.count(), 1);
        assertTrue(keys.has(_c(1), _c(2)));
    }

    function test_page_bounds() public {
        keys.add(_c(1), _c(2));
        keys.add(_c(3), _c(4));
        assertEq(keys.page(2, 10).length, 0); // offset == length
        assertEq(keys.page(5, 10).length, 0); // offset > length
        assertEq(keys.page(1, 10).length, 1); // tail clamped
        assertEq(keys.page(0, 1).length, 1); // limited
        assertEq(keys.page(0, type(uint256).max).length, 2); // no overflow
    }

    /// @dev Across an arbitrary add/remove sequence over 8 distinct keys, `count` and `page` length both
    ///      equal the number of present keys, and `has` agrees with each key's last op.
    function testFuzz_addRemove_countMatchesPresent(bool[8] calldata adds) public {
        uint256 expected;
        for (uint256 i = 0; i < 8; ++i) {
            Currency c = _c(uint160(100 + i));
            Currency d = _c(uint160(1000 + i));
            if (adds[i]) {
                keys.add(c, d);
                expected++;
            } else {
                keys.remove(c, d);
            }
        }
        assertEq(keys.count(), expected);
        assertEq(keys.page(0, type(uint256).max).length, expected);
        for (uint256 i = 0; i < 8; ++i) {
            assertEq(keys.has(_c(uint160(100 + i)), _c(uint160(1000 + i))), adds[i]);
        }
    }
}
