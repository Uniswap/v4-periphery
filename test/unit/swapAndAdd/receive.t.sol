// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import {ISwapAndAdd} from "../../../src/interfaces/ISwapAndAdd.sol";
import {BttBase} from "./BttBase.sol";

contract ReceiveTest is BttBase {
    function test_WhenSenderIsUnknown_Reverts() public {
        // it reverts with {InvalidEthSender}
        (bool ok, bytes memory data) = address(zap).call{value: 1 ether}("");
        assertFalse(ok, "unknown sender rejected");
        assertEq(bytes4(data), ISwapAndAdd.InvalidEthSender.selector, "InvalidEthSender");
    }

    function test_WhenSenderIsPoolManager_AcceptsNative() public {
        // it accepts native ETH
        vm.deal(address(manager), 1 ether);
        vm.prank(address(manager));
        (bool ok,) = address(zap).call{value: 1 ether}("");
        assertTrue(ok, "PoolManager may send native");
        assertEq(address(zap).balance, 1 ether, "ETH credited");
    }

    function test_WhenSenderIsPositionManager_AcceptsNative() public {
        // it accepts native ETH
        vm.deal(address(lpm), 1 ether);
        vm.prank(address(lpm));
        (bool ok,) = address(zap).call{value: 1 ether}("");
        assertTrue(ok, "POSM may send native");
        assertEq(address(zap).balance, 1 ether, "ETH credited");
    }

    function test_WhenSenderIsUniversalRouter_AcceptsNative() public {
        // it accepts native ETH
        vm.deal(address(route), 1 ether);
        vm.prank(address(route));
        (bool ok,) = address(zap).call{value: 1 ether}("");
        assertTrue(ok, "Universal Router may send native");
        assertEq(address(zap).balance, 1 ether, "ETH credited");
    }
}
