// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";

/// @title Permit2 Forwarder Interface
interface IPermit2Forwarder {
    /// @notice allows forwarding a single permit to permit2
    /// @dev this function is payable to allow multicall with NATIVE based actions
    function permit(address owner, IAllowanceTransfer.PermitSingle calldata permitSingle, bytes calldata signature)
        external
        payable;

    /// @notice allows forwarding batch permits to permit2
    /// @dev this function is payable to allow multicall with NATIVE based actions
    function permitBatch(address owner, IAllowanceTransfer.PermitBatch calldata _permitBatch, bytes calldata signature)
        external
        payable;
}
