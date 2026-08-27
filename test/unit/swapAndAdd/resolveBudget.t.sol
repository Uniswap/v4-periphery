// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import {ISwapAndAdd} from "../../../src/interfaces/ISwapAndAdd.sol";
import {BttBase} from "./BttBase.sol";

contract ResolveBudgetTest is BttBase {
    function test_WhenDeltaGteZero_ReturnsHeld() public {
        // it returns the full held balance
        uint256 held = 7e18;
        _fundZap(currency0, held);
        uint256 budget = zap.exposedResolveBudget(currency0, 1e18, address(this));
        assertEq(budget, held, "positive delta keeps full held");
        assertEq(currency0.balanceOf(address(zap)), held, "nothing transferred");
    }

    function test_WhenDeltaLtZeroAndToReturnLteHeld_PaysRecipient() public {
        // it transfers toReturn to recipient and returns held - toReturn
        address recipient = makeAddr("cashout");
        uint256 held = 10e18;
        int128 delta = -3e18;
        _fundZap(currency0, held);
        uint256 before = currency0.balanceOf(recipient);

        uint256 budget = zap.exposedResolveBudget(currency0, delta, recipient);

        assertEq(budget, 7e18, "remaining budget");
        assertEq(currency0.balanceOf(recipient), before + 3e18, "cash-out transferred");
        assertEq(currency0.balanceOf(address(zap)), 7e18, "zap retained remainder");
    }

    function test_WhenDeltaLtZeroAndToReturnGtHeld_Reverts() public {
        // it reverts with {ReturnExceedsWithdrawn}
        _fundZap(currency0, 1e18);
        vm.expectRevert(
            abi.encodeWithSelector(ISwapAndAdd.ReturnExceedsWithdrawn.selector, uint256(2e18), uint256(1e18))
        );
        zap.exposedResolveBudget(currency0, -2e18, address(this));
    }

    function test_WhenDeltaIsInt128Min_DoesNotOverflow() public {
        // it does not overflow the negation
        uint256 toReturn = uint256(-int256(type(int128).min));
        _fundZap(currency0, toReturn);
        address recipient = makeAddr("cashout");
        uint256 budget = zap.exposedResolveBudget(currency0, type(int128).min, recipient);
        assertEq(budget, 0, "entire held balance cashed out");
        assertEq(currency0.balanceOf(recipient), toReturn, "int128.min cash-out delivered");
    }
}
