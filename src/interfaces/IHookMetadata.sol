// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface IHookMetadata {
    // Struct representing the auditor of a smart contract
    struct Auditor {
        string name;       // Name of the auditor
        string uri;        // URI with additional information about the auditor
        string[] authors;  // List of authors who are responsible for the audit
    }

    // Struct representing a summary of the audit
    struct AuditSummary {
        Auditor auditor;         // The auditor who performed the audit
        uint256 issuedAt;        // The timestamp at which the audit was issued
        uint256[] ercs;          // List of ERC standards that were covered in the audit
        bytes32 codeHash;        // Hash of the audited smart contract code
        bytes32 auditHash;       // Hash of the audit document
        string auditUri;         // URI with additional information or the full audit report
    }

    // Struct representing the EIP712 domain, which is used for signatures
    struct EIP712Domain {
        string name;        // Name of the domain
        string version;     // Version of the domain
    }

    // Enum defining different types of signature standards
    enum SignatureType {
        SECP256K1,  // Standard ECDSA signature using secp256k1 curve
        BLS,        // BLS signature
        ERC1271,    // Signature type for smart contract based signatures (EIP-1271)
        SECP256R1   // ECDSA signature using secp256r1 curve
    }

    // Struct representing a cryptographic signature
    struct Signature {
        SignatureType signatureType; // Type of the signature (e.g., SECP256K1, BLS, etc.)
        bytes data;                  // Actual signature data
    }

    // Struct representing a signed audit summary
    struct SignedAuditSummary {
        AuditSummary auditSummary;       // The audit summary being signed
        uint256 signedAt;                // Timestamp indicating when the audit summary was signed
        Signature auditorSignature;      // Signature of the auditor for authenticity
    }

    // These are external functions that must be implemented by any contract that implements this interface

    function name() external view returns (string memory); // Returns the name of the hook
    function repository() external view returns (string memory); // Returns the repository URI for the smart contract code
    function logoURI() external view returns (string memory); // Returns the URI for the hook's logo
    function description() external view returns (string memory); // Returns a description of the hook
    function version() external view returns (bytes32); // Returns the version of the hook
    function auditSummary() external view returns (AuditSummary memory); // Returns the audit summary of the hook
    function eip712Domain() external view returns (EIP712Domain memory); // Returns the EIP712 domain details for signing purposes
    function signatureType() external view returns (SignatureType[] memory); // Returns the list of supported signature types
    function signature() external view returns (Signature memory); // Returns the signature details of a specific audit
    function signedAuditSummary() external view returns (SignedAuditSummary memory); // Returns a signed audit summary of the hook
}
