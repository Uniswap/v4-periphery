// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {Owner, NotOwner, ZeroOwner, NotPendingOwner} from "../../src/types/Owner.sol";

/// @notice Tiny harness that embeds an Owner and exposes all free functions at
///         external call boundaries so vm.expectRevert can capture their reverts.
contract OwnerHarness {
    Owner internal ownerStore;

    function writeOwner(address newOwner) external {
        ownerStore.write(newOwner);
    }

    function readOwner() external view returns (address) {
        return ownerStore.read();
    }

    function onlyOwner(address caller) external view {
        ownerStore.onlyOwner(caller);
    }

    function propose(address newOwner) external {
        ownerStore.propose(newOwner);
    }

    function acceptOwnership(address caller) external {
        ownerStore.acceptOwnership(caller);
    }

    function pendingOwner() external view returns (address) {
        return ownerStore.pendingOwner();
    }
}

/// @notice Fuzz tests for the Owner value type — access control, two-step
///         handoff, zero-address guards, and non-pending-caller guards.
contract OwnerFuzzTest is Test {
    OwnerHarness internal harness;

    function setUp() public {
        harness = new OwnerHarness();
    }

    // -------------------------------------------------------------------------
    // write / read round-trip
    // -------------------------------------------------------------------------

    /// write then read returns the written address.
    function testFuzz_writeRead_roundTrip(address owner) public {
        harness.writeOwner(owner);
        assertEq(harness.readOwner(), owner);
    }

    // -------------------------------------------------------------------------
    // onlyOwner
    // -------------------------------------------------------------------------

    /// onlyOwner passes for the owner and reverts NotOwner for any other caller.
    function testFuzz_onlyOwner_revertsForNonOwner(address owner, address caller) public {
        vm.assume(caller != owner);
        harness.writeOwner(owner);

        // owner succeeds
        harness.onlyOwner(owner);

        // non-owner reverts
        vm.expectRevert(abi.encodeWithSelector(NotOwner.selector, caller));
        harness.onlyOwner(caller);
    }

    /// onlyOwner passes for any owner address, including address(0).
    function testFuzz_onlyOwner_passesForOwner(address owner) public {
        harness.writeOwner(owner);
        harness.onlyOwner(owner); // must not revert
    }

    // -------------------------------------------------------------------------
    // propose
    // -------------------------------------------------------------------------

    /// propose sets pending without changing the current owner.
    function testFuzz_propose_setsPendingWithoutChangingOwner(address owner, address proposed) public {
        vm.assume(proposed != address(0));
        harness.writeOwner(owner);
        harness.propose(proposed);
        assertEq(harness.readOwner(), owner, "owner must not change yet");
        assertEq(harness.pendingOwner(), proposed, "pending must be set");
    }

    /// propose with address(0) reverts ZeroOwner.
    function testFuzz_propose_revertsForZeroAddress(address owner) public {
        harness.writeOwner(owner);
        vm.expectRevert(ZeroOwner.selector);
        harness.propose(address(0));
    }

    // -------------------------------------------------------------------------
    // acceptOwnership
    // -------------------------------------------------------------------------

    /// acceptOwnership completes the handoff when called by the pending owner.
    function testFuzz_acceptOwnership_completesHandoff(address owner, address successor) public {
        vm.assume(successor != address(0));
        harness.writeOwner(owner);
        harness.propose(successor);

        harness.acceptOwnership(successor);

        assertEq(harness.readOwner(), successor, "owner must be successor after accept");
        assertEq(harness.pendingOwner(), address(0), "pending must be cleared");
    }

    /// Any caller that is not the pending owner is rejected with NotPendingOwner.
    function testFuzz_acceptOwnership_revertsForNonPendingCaller(address owner, address successor, address other)
        public
    {
        vm.assume(successor != address(0));
        vm.assume(other != successor);
        harness.writeOwner(owner);
        harness.propose(successor);

        vm.expectRevert(abi.encodeWithSelector(NotPendingOwner.selector, other));
        harness.acceptOwnership(other);
    }

    /// acceptOwnership reverts when no handoff is in progress (pending == address(0)).
    function testFuzz_acceptOwnership_revertsWhenNonePending(address owner, address caller) public {
        harness.writeOwner(owner);
        // No propose, so pending is address(0) => any caller reverts.
        vm.expectRevert(abi.encodeWithSelector(NotPendingOwner.selector, caller));
        harness.acceptOwnership(caller);
    }

    // -------------------------------------------------------------------------
    // Full two-step round-trip
    // -------------------------------------------------------------------------

    /// Full flow: propose, only successor can accept, old owner retained until then.
    function testFuzz_fullHandoff(address owner, address successor, address stranger) public {
        vm.assume(successor != address(0));
        vm.assume(stranger != successor);

        harness.writeOwner(owner);
        harness.propose(successor);

        // old owner is still recognized during the pending window
        assertEq(harness.readOwner(), owner);
        harness.onlyOwner(owner); // must not revert

        // stranger cannot accept
        vm.expectRevert(abi.encodeWithSelector(NotPendingOwner.selector, stranger));
        harness.acceptOwnership(stranger);

        // successor accepts
        harness.acceptOwnership(successor);
        assertEq(harness.readOwner(), successor);
        assertEq(harness.pendingOwner(), address(0));
    }

    /// After a completed handoff the old owner is no longer authorized.
    function testFuzz_afterHandoff_oldOwnerReverts(address owner, address successor) public {
        vm.assume(successor != address(0));
        vm.assume(owner != successor);

        harness.writeOwner(owner);
        harness.propose(successor);
        harness.acceptOwnership(successor);

        vm.expectRevert(abi.encodeWithSelector(NotOwner.selector, owner));
        harness.onlyOwner(owner);
    }
}
