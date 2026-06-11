// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Minimal ownership concern: a single owner address with an access guard.
/// @dev Type-driven: a struct plus free functions bound `using ... for ... global`. Composed by
///      contracts that need governance gating, for example the lending adapter gates `setMarket`
///      with `store.owner.onlyOwner(msg.sender)`.
struct Owner {
    address _inner;
}

using {read, write, onlyOwner} for Owner global;

/// @notice Thrown when a non-owner calls an owner-gated function.
error NotOwner(address caller);

/// @notice The current owner.
function read(Owner storage self) view returns (address) {
    return self._inner;
}

/// @notice Sets the owner. Caller must gate access (e.g. behind `onlyOwner`).
function write(Owner storage self, address newOwner) returns (Owner storage) {
    self._inner = newOwner;
    return self;
}

/// @notice Reverts `NotOwner` unless `caller` is the owner.
function onlyOwner(Owner storage self, address caller) view {
    if (caller != self._inner) revert NotOwner(caller);
}
