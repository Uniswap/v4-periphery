// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IEIP712_v4} from "./IEIP712_v4.sol";
import {IEIP7512} from "./IEIP7512.sol";

/**
 * @title IHookMetadata
 * @notice This interface is designed so that external indexing services can discover
 *         and display essential information about a Uniswap v4 hook. It extends the
 *         on-chain audit representation outlined in EIP‑7512, thereby allowing the hook
 *         to store and provide signed audit summaries for third-party verification.
 *
 * ----------------------------------------------------------------------------
 * HOOK METADATA FLOW
 *
 * 1. Required Metadata
 *    - Every hook must implement: name(), repository(), logoURI(), websiteURI(),
 *      description(), version().
 *    - These fields are effectively immutable and indexed at deployment time.
 *
 * 2. Audit Summaries
 *    - The function auditSummaries(auditId) returns a completed audit summary.
 *    - Audits can be appended over time, and each newly added audit summary must
 *      emit the AuditSummaryRegistered event for indexers.
 *
 * 3. EIP-712 Domain Information
 *    - The contract must provide an EIP-712 DOMAIN_SEPARATOR to allow auditors
 *      to produce valid signatures for the audit summaries.
 *
 * 4. Signature Types
 *    - Auditors may choose from multiple signature standards (SECP256K1, BLS, ERC1271, SECP256R1)
 *    - The chosen SignatureType is stored alongside the signature data.
 *
 * 5. Auditor Process
 *    - The auditor generates an EIP-712 signature over the audit summary, choosing
 *      the appropriate SignatureType.
 *    - The final signed audit summary is then delivered to the hook owner/deployer.
 *
 * 6. Developer / Deployer Process
 *    - Implement this interface in the hook contract, storing all required metadata.
 *    - Emit the AuditSummaryRegistered event whenever a new audit summary is added.
 *    - Treat core metadata (name, repository, etc.) as immutable after deployment,
 *      but you may append new audit summaries as needed.
 *
 * ----------------------------------------------------------------------------
 *
 * For more details, see:
 * - EIP‑7512: https://eips.ethereum.org/EIPS/eip-7512
 * - EIP‑712:  https://eips.ethereum.org/EIPS/eip-712
 */
interface IHookMetadata is IEIP712_v4, IEIP7512 {
    /// @notice An error emitted when a wrong audit ID is used.
    error WrongAuditId();

    /// @notice Emitted when a new audit summary is registered.
    /// @dev This event must be emitted so that all indexing services can
    ///      index the newly added audit record.
    /// @param auditId The identifier for the audit record.
    /// @param auditHash The hash of the audit document.
    /// @param auditUri The URI pointing to additional audit info or the full report.
    event AuditSummaryRegistered(uint256 indexed auditId, bytes32 auditHash, string auditUri);

    /// @notice Returns the name of the hook.
    /// @return The hook's name as a string.
    function name() external view returns (string memory);

    /// @notice Returns the repository URI for the hook's source code.
    /// @return The repository URI.
    function repositoryURI() external view returns (string memory);

    /// @notice Returns the URI for the hook's logo.
    /// @return The logo URI.
    function logoURI() external view returns (string memory);

    /// @notice Returns the URI for the hook's website.
    /// @return The website URI.
    function websiteURI() external view returns (string memory);

    /// @notice Returns a description of the hook.
    /// @return The hook's description.
    function description() external view returns (string memory);

    /// @notice Returns the version of the hook.
    /// @return The version identifier as bytes32.
    function version() external view returns (bytes32);

    /// @notice Returns the audit summary record for a given audit ID.
    /// @param auditId The identifier used to look up a specific SignedAuditSummary.
    /// @return summary A SignedAuditSummary struct containing the audit details and signature.
    function auditSummaries(uint256 auditId) external view returns (SignedAuditSummary memory);
}
