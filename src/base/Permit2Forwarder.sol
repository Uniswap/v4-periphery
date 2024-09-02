// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.0;

import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";

/// @notice PermitForwarder allows permitting this contract as a spender on permit2
/// @dev This contract does not enforce the spender to be this contract, but that is the intended use case
contract Permit2Forwarder {
    IAllowanceTransfer public immutable permit2;

    constructor(IAllowanceTransfer _permit2) {
        permit2 = _permit2;
    }

    /// @notice allows forwarding a single permit to permit2
    /// @dev this function is payable to allow multicall with NATIVE based actions
    function permit(address owner, IAllowanceTransfer.PermitSingle calldata permitSingle, bytes calldata signature)
        external
        payable
    {
        permit2.permit(owner, permitSingle, signature);
    }

    /// @notice allows forwarding batch permits to permit2
    /// @dev this function is payable to allow multicall with NATIVE based actions
    function permitBatch(address owner, IAllowanceTransfer.PermitBatch calldata _permitBatch, bytes calldata signature)
        external
        payable
    {
        permit2.permit(owner, _permitBatch, signature);
    }
}
