// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {MockMulticall} from "../mock/MockMulticall.sol";

contract MulticallTest is Test {
    MockMulticall multicall;

    function setUp() public {
        multicall = new MockMulticall();
    }

    function test_multicall() public {
        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeWithSelector(MockMulticall(multicall).functionThatReturnsTuple.selector, 10, 20);
        calls[1] = abi.encodeWithSelector(MockMulticall(multicall).functionThatReturnsTuple.selector, 1, 2);

        bytes[] memory results = multicall.multicall(calls);

        (uint256 a, uint256 b) = abi.decode(results[0], (uint256, uint256));
        assertEq(a, 10);
        assertEq(b, 20);

        (a, b) = abi.decode(results[1], (uint256, uint256));
        assertEq(a, 1);
        assertEq(b, 2);
    }

    function test_multicall_firstRevert() public {
        bytes[] memory calls = new bytes[](2);
        calls[0] =
            abi.encodeWithSelector(MockMulticall(multicall).functionThatRevertsWithError.selector, "First call failed");
        calls[1] = abi.encodeWithSelector(MockMulticall(multicall).functionThatReturnsTuple.selector, 1, 2);

        vm.expectRevert("First call failed");
        multicall.multicall(calls);
    }

    function test_multicall_secondRevert() public {
        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeWithSelector(MockMulticall(multicall).functionThatReturnsTuple.selector, 1, 2);
        calls[1] =
            abi.encodeWithSelector(MockMulticall(multicall).functionThatRevertsWithError.selector, "Second call failed");

        vm.expectRevert("Second call failed");
        multicall.multicall(calls);
    }

    function test_multicall_pays() public {
        assertEq(address(multicall).balance, 0);
        bytes[] memory calls = new bytes[](1);
        calls[0] = abi.encodeWithSelector(MockMulticall(multicall).pays.selector);
        multicall.multicall{value: 100}(calls);
        assertEq(address(multicall).balance, 100);
        assertEq(multicall.paid(), 100);
    }

    function test_multicall_returnSender() public {
        bytes[] memory calls = new bytes[](1);
        calls[0] = abi.encodeWithSelector(MockMulticall(multicall).returnSender.selector);
        bytes[] memory results = multicall.multicall(calls);
        address sender = abi.decode(results[0], (address));
        assertEq(sender, address(this));
    }

    function test_multicall_returnSender_prank() public {
        address alice = makeAddr("ALICE");

        bytes[] memory calls = new bytes[](1);
        calls[0] = abi.encodeWithSelector(MockMulticall(multicall).returnSender.selector, alice);
        vm.prank(alice);
        bytes[] memory results = multicall.multicall(calls);
        address sender = abi.decode(results[0], (address));
        assertEq(sender, alice);
    }

    function test_multicall_double_send() public {
        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeWithSelector(MockMulticall(multicall).pays.selector);
        calls[1] = abi.encodeWithSelector(MockMulticall(multicall).pays.selector);

        multicall.multicall{value: 100}(calls);
        assertEq(address(multicall).balance, 100);
        assertEq(multicall.paid(), 100);
    }
}
