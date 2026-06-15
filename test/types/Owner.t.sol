// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {Owner, NotOwner, ZeroOwner, NotPendingOwner} from "../../src/types/Owner.sol";

contract OwnerTest is Test {
    Owner internal ownerStore;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    // external wrappers so vm.expectRevert catches the storage free-function reverts at a call boundary
    function onlyOwnerExt(address caller) external view {
        ownerStore.onlyOwner(caller);
    }

    function proposeExt(address newOwner) external {
        ownerStore.propose(newOwner);
    }

    function acceptOwnershipExt(address caller) external {
        ownerStore.acceptOwnership(caller);
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

    function test_propose_setsPendingWithoutChangingOwner() public {
        ownerStore.write(alice);
        ownerStore.propose(bob);
        assertEq(ownerStore.read(), alice); // owner unchanged until accept
        assertEq(ownerStore.pendingOwner(), bob);
    }

    function test_propose_revertsForZeroAddress() public {
        ownerStore.write(alice);
        vm.expectRevert(ZeroOwner.selector);
        this.proposeExt(address(0));
    }

    function test_acceptOwnership_completesHandoffAndClearsPending() public {
        ownerStore.write(alice);
        ownerStore.propose(bob);
        ownerStore.acceptOwnership(bob);
        assertEq(ownerStore.read(), bob);
        assertEq(ownerStore.pendingOwner(), address(0));
    }

    function test_acceptOwnership_revertsForNonPendingCaller() public {
        ownerStore.write(alice);
        ownerStore.propose(bob);
        vm.expectRevert(abi.encodeWithSelector(NotPendingOwner.selector, alice));
        this.acceptOwnershipExt(alice);
    }

    function test_acceptOwnership_revertsWhenNonePending() public {
        ownerStore.write(alice);
        vm.expectRevert(abi.encodeWithSelector(NotPendingOwner.selector, bob));
        this.acceptOwnershipExt(bob);
    }
}
