// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/**
 * @title IEIP7512
 * @notice This interface is used for an EIP7512 implementation.
 */
interface IEIP7512 {
    /// @notice Defines different types of signature standards.
    enum SignatureType {
        SECP256K1,
        BLS,
        ERC1271,
        SECP256R1
    }

    /// @notice Represents the auditor.
    /// @param name The name of the auditor.
    /// @param uri The URI with additional information about the auditor.
    /// @param authors List of authors responsible for the audit.
    struct Auditor {
        string name;
        string uri;
        string[] authors;
    }

    /// @notice Represents a summary of the audit.
    /// @param auditor The auditor who performed the audit.
    /// @param issuedAt The timestamp at which the audit was issued.
    /// @param ercs List of ERC standards that were covered in the audit.
    /// @param bytecodeHash Hash of the audited smart contract bytecode.
    /// @param auditHash Hash of the audit document.
    /// @param auditUri URI with additional information or the full audit report.
    struct AuditSummary {
        Auditor auditor;
        uint256 issuedAt;
        uint256[] ercs;
        bytes32 bytecodeHash;
        bytes32 auditHash;
        string auditUri;
    }

    /// @notice Represents a cryptographic signature.
    /// @param signatureType The type of the signature (e.g., SECP256K1, BLS, etc.).
    /// @param data The actual signature data.
    struct Signature {
        SignatureType signatureType;
        bytes data;
    }

    /// @notice Represents a signed audit summary.
    /// @param summary The audit summary being signed.
    /// @param signedAt Timestamp indicating when the audit summary was signed.
    /// @param auditorSignature Signature of the auditor for authenticity.
    struct SignedAuditSummary {
        AuditSummary summary;
        uint256 signedAt;
        Signature auditorSignature;
    }
}
