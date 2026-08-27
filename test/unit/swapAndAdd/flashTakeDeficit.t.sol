// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {BttBase} from "./BttBase.sol";
import {ISwapAndAddHarness} from "./ISwapAndAddHarness.sol";

contract FlashTakeDeficitTest is BttBase {
    using CurrencyLibrary for Currency;

    function test_WhenAmountsLteBudgets_TakesNothing() public {
        // it takes nothing
        uint256 c0Before = currency0.balanceOf(address(zap));
        uint256 c1Before = currency1.balanceOf(address(zap));
        ISwapAndAddHarness.CoreParams memory cp = _core(key, 10e18, 10e18);

        (int256 d0, int256 d1) = zap.exposedFlashTakeDeficit(cp, 5e18, 5e18);

        assertEq(d0, 0, "no token0 debt");
        assertEq(d1, 0, "no token1 debt");
        assertEq(currency0.balanceOf(address(zap)), c0Before, "token0 unchanged");
        assertEq(currency1.balanceOf(address(zap)), c1Before, "token1 unchanged");
    }

    function test_WhenAmount0GtBudget0_TakesToken0Shortfall() public {
        // it takes amount0 - budget0 of token0
        ISwapAndAddHarness.CoreParams memory cp = _core(key, 1e18, 10e18);
        uint256 c0Before = currency0.balanceOf(address(zap));

        (int256 d0, int256 d1) = zap.exposedFlashTakeDeficit(cp, 4e18, 5e18);

        assertEq(d0, -int256(3e18), "token0 flash debt");
        assertEq(d1, 0, "no token1 debt");
        // Harness closes the debt before unlock returns, so the take is observed only via the recorded delta.
        assertEq(currency0.balanceOf(address(zap)), c0Before, "flash take settled before return");
    }

    function test_WhenAmount1GtBudget1_TakesToken1Shortfall() public {
        // it takes amount1 - budget1 of token1
        ISwapAndAddHarness.CoreParams memory cp = _core(key, 10e18, 1e18);
        uint256 c1Before = currency1.balanceOf(address(zap));

        (int256 d0, int256 d1) = zap.exposedFlashTakeDeficit(cp, 5e18, 6e18);

        assertEq(d0, 0, "no token0 debt");
        assertEq(d1, -int256(5e18), "token1 flash debt");
        assertEq(currency1.balanceOf(address(zap)), c1Before, "flash take settled before return");
    }

    function test_WhenBothAmountsExceedBudgets_TakesBoth() public {
        // it takes the shortfall on both tokens
        ISwapAndAddHarness.CoreParams memory cp = _core(key, 1e18, 2e18);
        uint256 c0Before = currency0.balanceOf(address(zap));
        uint256 c1Before = currency1.balanceOf(address(zap));

        (int256 d0, int256 d1) = zap.exposedFlashTakeDeficit(cp, 4e18, 5e18);

        assertEq(d0, -int256(3e18), "token0 shortfall");
        assertEq(d1, -int256(3e18), "token1 shortfall");
        assertEq(currency0.balanceOf(address(zap)), c0Before, "token0 settled");
        assertEq(currency1.balanceOf(address(zap)), c1Before, "token1 settled");
    }
}
