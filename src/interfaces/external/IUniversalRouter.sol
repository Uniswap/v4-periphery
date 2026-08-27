// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

/// @notice Minimal Universal Router interface used by SwapAndAdd for the route leg.
/// @dev The route runs verbatim. The within-unlock V4_SWAP handling is internal to the router.
interface IUniversalRouter {
    function execute(bytes calldata commands, bytes[] calldata inputs) external payable;
}
