// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IEIP712_v4} from "../interfaces/IEIP712_v4.sol";

/// @notice Generic EIP712 implementation
/// @dev Maintains cross-chain replay protection in the event of a fork
/// @dev Should not be delegatecall'd because DOMAIN_SEPARATOR returns the cached hash and does not recompute with the delegatecallers address
/// @dev Reference: https://github.com/Uniswap/permit2/blob/3f17e8db813189a03950dc7fc8382524a095c053/src/EIP712.sol
/// @dev Reference: https://github.com/OpenZeppelin/openzeppelin-contracts/blob/7bd2b2aaf68c21277097166a9a51eb72ae239b34/contracts/utils/cryptography/EIP712.sol
contract EIP712_v4 is IEIP712_v4 {
    // Cache the domain separator as an immutable value, but also store the chain id that it
    // corresponds to, in order to invalidate the cached domain separator if the chain id changes.
    bytes32 private immutable _CACHED_DOMAIN_SEPARATOR;
    uint256 private immutable _CACHED_CHAIN_ID;
    bytes32 private immutable _HASHED_NAME;

    bytes32 private constant _TYPE_HASH =
        keccak256("EIP712Domain(string name,uint256 chainId,address verifyingContract)");

    constructor(string memory name) {
        _HASHED_NAME = keccak256(bytes(name));

        _CACHED_CHAIN_ID = block.chainid;
        _CACHED_DOMAIN_SEPARATOR = _buildDomainSeparator();
    }

    /// @inheritdoc IEIP712_v4
    function DOMAIN_SEPARATOR() public view returns (bytes32) {
        // uses cached version if chainid is unchanged from construction
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

            // now clean the memory we used
            mstore(fmp, 0) // fmp held "\x19\x01", domainSeparator
            mstore(add(fmp, 0x20), 0) // fmp+0x20 held domainSeparator, dataHash
            mstore(add(fmp, 0x40), 0) // fmp+0x40 held dataHash
        }
    }
}
