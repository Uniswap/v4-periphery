// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IHookMetadata} from "../../interfaces/IHookMetadata.sol";

/**
 * @title HookMetadata
 * @notice An abstract implementation of the HookMetadata contract wich internaly implements registration of audits
 *         summaries and their retrivals using internal counting mechanism.
 */
abstract contract HookMetadata is IHookMetadata {
    mapping(uint256 auditId => SignedAuditSummary signedAuditSummary) private signedAuditsSummaries;
    uint256 public auditsCount;

    /// @notice Returns a summary about audit using signed audit ID.
    /// @dev Throws an error in case of wrong audit ID.
    /// @param auditId An ID of the audit to retrieve information about.
    function auditSummaries(uint256 auditId) external view returns (SignedAuditSummary memory) {
        if (auditId < auditsCount)
            return signedAuditsSummaries[auditId];

        revert IHookMetadata.WrongAuditId();
    }

    /// @notice An internal method that registers a new signed audit summury and emits an event that may be useful for
    ///         external indexing services to discover and display essential information about a Uniswap V4 hook.
    /// @dev This internal method should be called in the child hook contract whenever new audit summary is registered
    ///      (for example, in the constructor or in the custom owner/admin/DAO controlled method).
    /// @param signedAuditSummary A new signed audit summury to register.
    /// @return A new signed audit summary ID.
    function _registerAuditSummary(SignedAuditSummary calldata signedAuditSummary) internal returns (uint256) {
        uint256 _auditsCount = auditsCount;

        signedAuditsSummaries[_auditsCount] = signedAuditSummary;

        emit AuditSummaryRegistered(
            _auditsCount, signedAuditSummary.summary.auditHash, signedAuditSummary.summary.auditUri
        );

        ++auditsCount;

        return _auditsCount;
    }
}
