// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

/// @notice Minimal Universal Router interface used by SwapAndAdd to delegate the bulk swap leg.
/// @dev We intentionally depend only on this interface (not on the UR source), keeping the dependency
///      direction clean. The route runs verbatim; the within-unlock V4_SWAP handling is internal to UR.
interface IUniversalRouter {
    function execute(bytes calldata commands, bytes[] calldata inputs) external payable;
}
