// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IEIP712_v4} from "../interfaces/IEIP712_v4.sol";

/// @notice Generic EIP712 implementation
/// @dev Maintains cross-chain replay protection in the event of a fork
/// @dev Should not be delegatecall'd because DOMAIN_SEPARATOR returns the cached hash and does not recompute with the delegatecallers address
/// @dev Reference: https://github.com/Uniswap/permit2/blob/main/src/EIP712.sol
/// @dev Reference: https://github.com/OpenZeppelin/openzeppelin-contracts/blob/master/contracts/utils/cryptography/EIP712.sol
contract EIP712_v4 is IEIP712_v4 {
    // Cache the domain separator as an immutable value, but also store the chain id that it
    // corresponds to, in order to invalidate the cached domain separator if the chain id changes.
    bytes32 private immutable _CACHED_DOMAIN_SEPARATOR;
    uint256 private immutable _CACHED_CHAIN_ID;
    bytes32 private immutable _HASHED_NAME;

    /// @dev equal to keccak256("EIP712Domain(string name,uint256 chainId,address verifyingContract)")
    bytes32 private constant _TYPE_HASH = 0x8cad95687ba82c2ce50e74f7b754645e5117c3a5bec8151c0726d5857980a866;

    constructor(string memory name) {
        _HASHED_NAME = keccak256(bytes(name));

        _CACHED_CHAIN_ID = block.chainid;
        _CACHED_DOMAIN_SEPARATOR = _buildDomainSeparator();
    }

    /// @notice Returns the domain separator for the current chain.
    /// @dev Uses cached version if chainid is unchanged from construction.
    function DOMAIN_SEPARATOR() public view override returns (bytes32) {
        return block.chainid == _CACHED_CHAIN_ID ? _CACHED_DOMAIN_SEPARATOR : _buildDomainSeparator();
    }

    /// @notice Builds a domain separator using the current chainId and contract address.
    function _buildDomainSeparator() private view returns (bytes32) {
        return keccak256(abi.encode(_TYPE_HASH, _HASHED_NAME, block.chainid, address(this)));
    }

    /// @notice Creates an EIP-712 typed data hash
    function _hashTypedData(bytes32 dataHash) internal view returns (bytes32 digest) {
        // equal to keccak256(abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR(), dataHash));
        bytes32 domainSeparator = DOMAIN_SEPARATOR();
        assembly ("memory-safe") {
            let fmp := mload(0x40)
            mstore(fmp, hex"1901")
            mstore(add(fmp, 0x02), domainSeparator)
            mstore(add(fmp, 0x22), dataHash)
            digest := keccak256(fmp, 0x42)
        }
    }
}
