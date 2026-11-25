// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

/// @notice Minimal Universal Router interface.
interface IUniversalRouter {
    function execute(bytes calldata commands, bytes[] calldata inputs) external payable;

    /// @notice Runs the commands inside the caller's open PoolManager unlock (Universal Router 2.3.0+).
    function executeNested(bytes calldata commands, bytes[] calldata inputs) external payable;
}
