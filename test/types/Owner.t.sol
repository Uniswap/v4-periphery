// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {Owner, NotOwner} from "../../src/types/Owner.sol";

contract OwnerTest is Test {
    Owner internal ownerStore;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    // external wrapper so vm.expectRevert catches the storage free-function revert at a call boundary
    function onlyOwnerExt(address caller) external view {
        ownerStore.onlyOwner(caller);
    }

    function test_write_and_read() public {
        ownerStore.write(alice);
        assertEq(ownerStore.read(), alice);
    }

    function test_onlyOwner_passesForOwner() public {
        ownerStore.write(alice);
        this.onlyOwnerExt(alice); // does not revert
    }

    function test_onlyOwner_revertsForNonOwner() public {
        ownerStore.write(alice);
        vm.expectRevert(abi.encodeWithSelector(NotOwner.selector, bob));
        this.onlyOwnerExt(bob);
    }
}
