// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title Owner
/// @author Uniswap Labs
/// @notice Minimal ownership concern: a single owner address with an access guard and a two-step
///         handoff. Type-driven: a struct plus free functions bound `using ... for ... global`.
///         Composed by contracts that need governance gating; for example, `OwnableAdapter` holds one
///         and the lending adapters gate `setMarket` through its `_onlyOwner`. Handoffs are two-step: the current
///         owner `propose`s a successor, who must then `acceptOwnership`. A zero-address successor is
///         rejected, so the role can never be transferred to an unrecoverable address.
/// @param _current The current owner address. Read via `read()`; mutated via `write()` and
///        `acceptOwnership()`.
/// @param _pending The address proposed as the next owner, or `address(0)` when none is pending.
///        Read via `pendingOwner()`; set via `propose()`; cleared on `acceptOwnership()`.
struct Owner {
    address _current;
    address _pending;
}

using {read, write, onlyOwner, propose, acceptOwnership, pendingOwner} for Owner global;

/// @dev Thrown when a non-owner calls an owner-gated function.
/// @param caller The address that attempted the call.
error NotOwner(address caller);

/// @dev Thrown when `propose` is given the zero address as the next owner. Transferring the role to
///      the zero address would brick it permanently, since `onlyOwner` would then always revert.
error ZeroOwner();

/// @dev Thrown when a caller that is not the currently pending owner calls `acceptOwnership`, or when
///      no successor is pending.
/// @param caller The address that attempted to accept ownership.
error NotPendingOwner(address caller);

/// @notice Returns the current owner.
/// @param self The `Owner` storage to read.
/// @return The current owner address.
function read(Owner storage self) view returns (address) {
    return self._current;
}

/// @notice Sets the owner directly, without the two-step handoff. Used to seed the initial owner at
///         construction. The caller must gate access (e.g. by calling `onlyOwner` first); this
///         function performs no authorization itself. Reverts `ZeroOwner` on the zero address, so a
///         constructor cannot seed an unrecoverable owner (mirrors the guard on `propose`).
/// @param self The `Owner` storage to update.
/// @param newOwner The new owner address.
/// @return The same storage reference, for chaining.
function write(Owner storage self, address newOwner) returns (Owner storage) {
    if (newOwner == address(0)) revert ZeroOwner();
    self._current = newOwner;
    return self;
}

/// @notice Reverts `NotOwner` unless `caller` is the current owner.
/// @param self The `Owner` storage to check against.
/// @param caller The address to authorize; typically `msg.sender`.
function onlyOwner(Owner storage self, address caller) view {
    if (caller != self._current) revert NotOwner(caller);
}

/// @notice Proposes a successor for the two-step handoff. The successor takes effect only once it
///         calls `acceptOwnership`; the current owner remains authorized until then. Reverts
///         `ZeroOwner` if `newOwner` is the zero address. The caller must gate access (e.g. by
///         calling `onlyOwner` first); this function performs no authorization itself.
/// @param self The `Owner` storage to update.
/// @param newOwner The address proposed as the next owner.
/// @return The same storage reference, for chaining.
function propose(Owner storage self, address newOwner) returns (Owner storage) {
    if (newOwner == address(0)) revert ZeroOwner();
    self._pending = newOwner;
    return self;
}

/// @notice Completes the two-step handoff. Reverts `NotPendingOwner` unless a successor is pending
///         and `caller` is that successor. On success the pending owner becomes the current owner and
///         the pending slot is cleared.
/// @param self The `Owner` storage to update.
/// @param caller The address accepting ownership; typically `msg.sender`.
function acceptOwnership(Owner storage self, address caller) {
    // _pending is zero when no handoff is in progress; a real caller is never zero, so this single
    // check also rejects an accept with nothing pending
    if (caller != self._pending) revert NotPendingOwner(caller);
    self._current = self._pending;
    self._pending = address(0);
}

/// @notice Returns the address proposed as the next owner, or `address(0)` when none is pending.
/// @param self The `Owner` storage to read.
/// @return The pending owner address.
function pendingOwner(Owner storage self) view returns (address) {
    return self._pending;
}
