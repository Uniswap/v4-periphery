// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title BatchExecutor
/// @author Uniswap Labs
/// @notice A minimal EIP-7702 delegate. An EOA that delegates its code here can run an ordered batch
///         of calls atomically in a single transaction. It is reusable, chain-agnostic infrastructure
///         (deploy once per chain at a deterministic address): the margin stack's one-tx deploy uses
///         it to route each contract deploy through the standard CREATE2 factory and then make the
///         allowlist, market, and governance-handoff calls, all in one transaction as the EOA.
/// @dev The batch is gated to self-calls only: `execute` requires `msg.sender == address(this)`, so
///      when the EOA (whose code is delegated here) sends a transaction to itself the batch runs, but
///      a third party cannot drive the EOA's delegated code even though a 7702 delegation persists on
///      the account until it is changed. The contract holds no state and no funds between calls.
contract BatchExecutor {
    /// @notice One call in a batch.
    /// @param target The address to call (the CREATE2 factory for a deploy, or a deployed contract
    ///        for a config call).
    /// @param value The wei to forward with the call.
    /// @param data The calldata (for a factory deploy, `abi.encodePacked(salt, initCode)`).
    struct Call {
        address target;
        uint256 value;
        bytes data;
    }

    /// @dev Thrown when `execute` is called by anything other than the account itself. Blocks a third
    ///      party from driving a persisted 7702 delegation.
    error Unauthorized();

    /// @dev Thrown when a call in the batch reverts, identifying which one and bubbling its revert data.
    /// @param index The index of the failing call in the batch.
    /// @param returnData The raw revert data returned by the failing call.
    error CallFailed(uint256 index, bytes returnData);

    /// @notice Runs `calls` in order, reverting the whole batch if any call fails.
    /// @dev Callable only via a self-call (`msg.sender == address(this)`), i.e. the delegating EOA
    ///      sending a transaction to itself. Payable so a deploy call can forward value if ever needed.
    /// @param calls The ordered calls to execute.
    function execute(Call[] calldata calls) external payable {
        if (msg.sender != address(this)) revert Unauthorized();
        for (uint256 i; i < calls.length; i++) {
            (bool ok, bytes memory ret) = calls[i].target.call{value: calls[i].value}(calls[i].data);
            if (!ok) revert CallFailed(i, ret);
        }
    }
}
