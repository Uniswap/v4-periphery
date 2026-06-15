// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title Owner
/// @author Uniswap Labs
/// @notice Minimal ownership concern: a single owner address with an access guard. Type-driven: a
///         struct plus free functions bound `using ... for ... global`. Composed by contracts that
///         need governance gating; for example, the lending adapter gates `setMarket` with
///         `store.owner.onlyOwner(msg.sender)`.
/// @param _inner The current owner address. Read via `read()`; mutated via `write()`.
struct Owner {
    address _inner;
}

using {read, write, onlyOwner} for Owner global;

/// @dev Thrown when a non-owner calls an owner-gated function.
/// @param caller The address that attempted the call.
error NotOwner(address caller);

/// @notice Returns the current owner.
/// @param self The `Owner` storage to read.
/// @return The current owner address.
function read(Owner storage self) view returns (address) {
    return self._inner;
}

/// @notice Sets the owner. The caller must gate access (e.g. by calling `onlyOwner` first);
///         this function performs no authorization itself.
/// @param self The `Owner` storage to update.
/// @param newOwner The new owner address.
/// @return The same storage reference, for chaining.
function write(Owner storage self, address newOwner) returns (Owner storage) {
    self._inner = newOwner;
    return self;
}

/// @notice Reverts `NotOwner` unless `caller` is the current owner.
/// @param self The `Owner` storage to check against.
/// @param caller The address to authorize; typically `msg.sender`.
function onlyOwner(Owner storage self, address caller) view {
    if (caller != self._inner) revert NotOwner(caller);
}
