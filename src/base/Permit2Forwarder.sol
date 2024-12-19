// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IPermit2Forwarder, IAllowanceTransfer} from "../interfaces/IPermit2Forwarder.sol";

/// @notice Permit2Forwarder allows permitting this contract as a spender on permit2
/// @dev This contract does not enforce the spender to be this contract, but that is the intended use case
contract Permit2Forwarder is IPermit2Forwarder {
    /// @notice the Permit2 contract to forward approvals
    IAllowanceTransfer public immutable permit2;

    constructor(IAllowanceTransfer _permit2) {
        permit2 = _permit2;
    }

    /// @inheritdoc IPermit2Forwarder
    function permit(address owner, IAllowanceTransfer.PermitSingle calldata permitSingle, bytes calldata signature)
        external
        payable
        returns (bytes memory err)
    {
        // use try/catch in case an actor front-runs the permit, which would DOS multicalls
        try permit2.permit(owner, permitSingle, signature) {}
        catch (bytes memory reason) {
            err = reason;
        }
    }

    /// @inheritdoc IPermit2Forwarder
    function permitBatch(address owner, IAllowanceTransfer.PermitBatch calldata _permitBatch, bytes calldata signature)
        external
        payable
        returns (bytes memory err)
    {
        // use try/catch in case an actor front-runs the permit, which would DOS multicalls
        try permit2.permit(owner, _permitBatch, signature) {}
        catch (bytes memory reason) {
            err = reason;
        }
    }
}
