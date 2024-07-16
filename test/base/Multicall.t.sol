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

        // First call should revert
        (uint256 a, uint256 b) = abi.decode(results[0], (uint256, uint256));
        assertEq(a, 10);
        assertEq(b, 20);

        // Second call should return a tuple
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
        multicall.pays{value: 100}();
        assertEq(address(multicall).balance, 100);
    }

    function test_multicall_returnSender() public view {
        assertEq(multicall.returnSender(), address(this));
    }

    function test_multicall_returnSender_prank() public {
        address alice = makeAddr("ALICE");
        vm.prank(alice);
        address sender = multicall.returnSender();
        assertEq(sender, alice);
    }
}
