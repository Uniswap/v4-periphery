// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {BttBase} from "./BttBase.sol";
import {ISwapAndAddHarness} from "./ISwapAndAddHarness.sol";

contract ExecuteRouteTest is BttBase {
    using CurrencyLibrary for Currency;

    function test_WhenRouterHoldsNoNative_DoesNotSweep() public {
        // it does not issue a sweep
        _configRoute(10000, 1e18);
        _fundZap(currency1, 10e18);
        zap.exposedEnsureApproved(currency1);

        ISwapAndAddHarness.CoreParams memory cp = _core(key, 0, 10e18);
        cp.route = ROUTE_PAYLOAD;
        uint256 zapEthBefore = address(zap).balance;

        zap.exposedExecuteRoute(cp);

        assertEq(address(zap).balance, zapEthBefore, "no native sweep");
        assertEq(address(route).balance, 0, "router native empty");
    }

    function test_WhenRouterHoldsNative_SweepsFullBalance() public {
        // it sweeps the full native balance back to the zap
        _configRoute(10000, 0);
        vm.deal(address(route), 1 ether);

        ISwapAndAddHarness.CoreParams memory cp = _core(key, 0, 0);
        cp.route = ROUTE_PAYLOAD;
        uint256 zapEthBefore = address(zap).balance;

        zap.exposedExecuteRoute(cp);

        assertEq(address(route).balance, 0, "router emptied");
        assertEq(address(zap).balance, zapEthBefore + 1 ether, "native reclaimed");
    }
}
