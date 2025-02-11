// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface IHookMetadata {
    /// @notice Represents the auditor
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

    /// @notice Defines different types of signature standards.
    enum SignatureType {
        SECP256K1,
        BLS,
        ERC1271,
        SECP256R1
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

    /// @notice Returns the name of the hook.
    /// @return The hook's name as a string.
    function name() external view returns (string memory);

    /// @notice Returns the repository URI for the smart contract code.
    /// @return The repository URI.
    function repository() external view returns (string memory);

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

    /// @notice Returns all audit records of the hook.
    /// @return An array of SignedAuditSummary structs containing audit summary and signature details.
    function audits() external view returns (SignedAuditSummary[] memory);
}
