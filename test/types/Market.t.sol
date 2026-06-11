// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";

import {Market, MarketSwapMismatch} from "../../src/types/Market.sol";

contract MarketTest is Test {
    Currency internal c0 = Currency.wrap(address(0x1111)); // c0 < c1
    Currency internal c1 = Currency.wrap(address(0x2222));
    Currency internal other = Currency.wrap(address(0x9999));

    function _poolKey(Currency a, Currency b) internal pure returns (PoolKey memory) {
        return PoolKey({currency0: a, currency1: b, fee: 3000, tickSpacing: 60, hooks: IHooks(address(0))});
    }

    // external wrapper so vm.expectRevert catches the free-function revert at a call boundary
    function toSwapParamsExt(Market memory m, Currency input, PoolKey memory key)
        external
        pure
        returns (bool zeroForOne)
    {
        return m.toSwapParams(input, -1e18, 0, key).zeroForOne;
    }

    function test_eq() public view {
        Market memory m = Market({collateral: c0, debt: c1});
        assertTrue(m.eq(Market({collateral: c0, debt: c1})));
        assertFalse(m.eq(Market({collateral: c1, debt: c0})));
    }

    function test_hasCurrencies_isOrderIndependent() public view {
        Market memory m = Market({collateral: c0, debt: c1});
        assertTrue(m.hasCurrencies(c0, c1));
        assertTrue(m.hasCurrencies(c1, c0));
        assertFalse(m.hasCurrencies(c0, other));
    }

    function test_toSwapParams_sellingCurrency0_isZeroForOne() public view {
        // debt is currency0; opening sells the debt => zeroForOne == true
        Market memory m = Market({collateral: c1, debt: c0});
        SwapParams memory p = m.toSwapParams(c0, -1e18, 0, _poolKey(c0, c1));
        assertTrue(p.zeroForOne);
        assertEq(p.amountSpecified, -1e18);
    }

    function test_toSwapParams_sellingCurrency1_isNotZeroForOne() public view {
        // debt is currency1; opening sells the debt => zeroForOne == false
        Market memory m = Market({collateral: c0, debt: c1});
        SwapParams memory p = m.toSwapParams(c1, -1e18, 0, _poolKey(c0, c1));
        assertFalse(p.zeroForOne);
    }

    function test_toSwapParams_revertsWhenPoolDoesNotMatchMarket() public {
        Market memory m = Market({collateral: c0, debt: c1});
        vm.expectRevert(MarketSwapMismatch.selector);
        this.toSwapParamsExt(m, c0, _poolKey(c0, other));
    }

    function test_toSwapParams_revertsWhenInputNotInMarket() public {
        Market memory m = Market({collateral: c0, debt: c1});
        vm.expectRevert(MarketSwapMismatch.selector);
        this.toSwapParamsExt(m, other, _poolKey(c0, c1));
    }
}
