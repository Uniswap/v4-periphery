//SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";

import {SafeCallback} from "../src/base/SafeCallback.sol";
import {ImmutableState} from "../src/base/ImmutableState.sol";
import {MockSafeCallback} from "./mocks/MockSafeCallback.sol";

contract SafeCallbackTest is Test, Deployers {
    MockSafeCallback safeCallback;

    function setUp() public {
        deployFreshManager();
        safeCallback = new MockSafeCallback(manager);
    }

    function test_poolManagerAddress() public view {
        assertEq(address(safeCallback.poolManager()), address(manager));
    }

    function test_unlock(uint256 num) public {
        bytes memory result = safeCallback.unlockManager(num);
        assertEq(num, abi.decode(result, (uint256)));
    }

    function test_unlockRevert(address caller, bytes calldata data) public {
        vm.startPrank(caller);
        if (caller != address(manager)) vm.expectRevert(ImmutableState.NotPoolManager.selector);
        safeCallback.unlockCallback(data);
        vm.stopPrank();
    }
}
