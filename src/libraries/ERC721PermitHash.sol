// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

library ERC721PermitHash {
    /// @dev Value is equal to keccak256("Permit(address spender,uint256 tokenId,uint256 nonce,uint256 deadline)");
    bytes32 constant PERMIT_TYPEHASH = 0x49ecf333e5b8c95c40fdafc95c1ad136e8914a8fb55e9dc8bb01eaa83a2df9ad;

    /// @dev Value is equal to keccak256("PermitForAll(address operator,bool approved,uint256 nonce,uint256 deadline)");
    bytes32 constant PERMIT_FOR_ALL_TYPEHASH = 0x6673cb397ee2a50b6b8401653d3638b4ac8b3db9c28aa6870ffceb7574ec2f76;

    /// @notice Hashes the data that will be signed for IERC721Permit_v4.permit()
    /// @param spender The address which may spend the tokenId
    /// @param tokenId The tokenId of the owner, which may be spent by spender
    /// @param nonce A unique non-ordered value for each signature to prevent replay attacks
    /// @param deadline The time at which the signature expires
    /// @return digest The hash of the data to be signed; the equivalent to keccak256(abi.encode(PERMIT_TYPEHASH, spender, tokenId, nonce, deadline));
    function hashPermit(address spender, uint256 tokenId, uint256 nonce, uint256 deadline)
        internal
        pure
        returns (bytes32 digest)
    {
        // equivalent to: keccak256(abi.encode(PERMIT_TYPEHASH, spender, tokenId, nonce, deadline));
        assembly ("memory-safe") {
            let fmp := mload(0x40)
            mstore(fmp, PERMIT_TYPEHASH)
            mstore(add(fmp, 0x20), and(spender, 0xffffffffffffffffffffffffffffffffffffffff))
            mstore(add(fmp, 0x40), tokenId)
            mstore(add(fmp, 0x60), nonce)
            mstore(add(fmp, 0x80), deadline)
            digest := keccak256(fmp, 0xa0)

            // now clean the memory we used
            mstore(fmp, 0) // fmp held PERMIT_TYPEHASH
            mstore(add(fmp, 0x20), 0) // fmp+0x20 held spender
            mstore(add(fmp, 0x40), 0) // fmp+0x40 held tokenId
            mstore(add(fmp, 0x60), 0) // fmp+0x60 held nonce
            mstore(add(fmp, 0x80), 0) // fmp+0x80 held deadline
        }
    }

    /// @notice Hashes the data that will be signed for IERC721Permit_v4.permit()
    /// @param operator The address which may spend any of the owner's tokenIds
    /// @param approved true if the operator is to have full permission over the owner's tokenIds; false otherwise
    /// @param nonce A unique non-ordered value for each signature to prevent replay attacks
    /// @param deadline The time at which the signature expires
    /// @return digest The hash of the data to be signed; the equivalent to keccak256(abi.encode(PERMIT_FOR_ALL_TYPEHASH, operator, approved, nonce, deadline));
    function hashPermitForAll(address operator, bool approved, uint256 nonce, uint256 deadline)
        internal
        pure
        returns (bytes32 digest)
    {
        // equivalent to: keccak256(abi.encode(PERMIT_FOR_ALL_TYPEHASH, operator, approved, nonce, deadline));
        assembly ("memory-safe") {
            let fmp := mload(0x40)
            mstore(fmp, PERMIT_FOR_ALL_TYPEHASH)
            mstore(add(fmp, 0x20), and(operator, 0xffffffffffffffffffffffffffffffffffffffff))
            mstore(add(fmp, 0x40), and(approved, 0x1))
            mstore(add(fmp, 0x60), nonce)
            mstore(add(fmp, 0x80), deadline)
            digest := keccak256(fmp, 0xa0)

            // now clean the memory we used
            mstore(fmp, 0) // fmp held PERMIT_FOR_ALL_TYPEHASH
            mstore(add(fmp, 0x20), 0) // fmp+0x20 held operator
            mstore(add(fmp, 0x40), 0) // fmp+0x40 held approved
            mstore(add(fmp, 0x60), 0) // fmp+0x60 held nonce
            mstore(add(fmp, 0x80), 0) // fmp+0x80 held deadline
        }
    }
}
