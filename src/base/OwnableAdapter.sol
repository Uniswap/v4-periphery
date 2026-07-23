// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Owner} from "../types/Owner.sol";

/// @title OwnableAdapter
/// @author Uniswap Labs
/// @notice Two-step ownable base shared by the lending adapters. It holds the governed owner guard
///         and exposes the standard `owner`/`pendingOwner`/`acceptOwnership`/`transferOwnership`
///         surface, so each adapter only has to route its market-curation calls through `_onlyOwner`.
/// @dev    Type-driven: the owner concern is the `Owner` struct plus its free functions. This base is
///         the thin contract shell that turns those into the external ABI and the constructor wiring.
///         The lending adapters are non-upgradeable singletons, so composing the guard here (ahead of
///         each adapter's own storage) is free of layout-compatibility concerns.
abstract contract OwnableAdapter {
    /// @notice The owner guard: the current owner plus any pending successor. Gates each adapter's
    ///         market curation via `_onlyOwner` and its `transferOwnership` handoff.
    Owner internal _owner;

    /// @param owner_ The initial adapter owner (governance).
    constructor(address owner_) {
        _owner.write(owner_);
    }

    /// @notice The current adapter owner (governance). Only the owner may curate markets and begin an
    ///         ownership handoff.
    /// @return The current owner address.
    function owner() external view returns (address) {
        return _owner.read();
    }

    /// @notice The address proposed to become owner, pending its acceptance. Zero when no handoff is
    ///         in progress.
    /// @return The pending owner address.
    function pendingOwner() external view returns (address) {
        return _owner.pendingOwner();
    }

    /// @notice Completes an ownership handoff. Callable by anyone, but only the address previously
    ///         named by `transferOwnership` succeeds; all others revert. On success the caller becomes
    ///         the owner.
    function acceptOwnership() external {
        _owner.acceptOwnership(msg.sender);
    }

    /// @notice Begins a two-step ownership handoff by proposing a successor. The successor takes
    ///         effect only once it calls `acceptOwnership`; the current owner retains its powers until
    ///         then, and the zero address is rejected so the role cannot be bricked. Owner-gated.
    /// @param newOwner The address proposed to become the new owner.
    function transferOwnership(address newOwner) external {
        _owner.onlyOwner(msg.sender);
        _owner.propose(newOwner);
    }

    /// @notice Reverts `NotOwner` unless the caller is the current owner.
    function _onlyOwner() internal view {
        _owner.onlyOwner(msg.sender);
    }
}
