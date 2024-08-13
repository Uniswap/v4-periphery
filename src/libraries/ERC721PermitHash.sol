// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

library ERC721PermitHashLibrary {
    /// @dev Value is equal to keccak256("Permit(address spender,uint256 tokenId,uint256 nonce,uint256 deadline)");
    bytes32 constant PERMIT_TYPEHASH = 0x49ecf333e5b8c95c40fdafc95c1ad136e8914a8fb55e9dc8bb01eaa83a2df9ad;

    /// @dev Value is equal to keccak256("PermitForAll(address operator,bool approved,uint256 nonce,uint256 deadline)");
    bytes32 constant PERMIT_FOR_ALL_TYPEHASH = 0x6673cb397ee2a50b6b8401653d3638b4ac8b3db9c28aa6870ffceb7574ec2f76;

    function hashPermit(address spender, uint256 tokenId, uint256 nonce, uint256 deadline)
        internal
        pure
        returns (bytes32 digest)
    {
        // equivalent to: keccak256(abi.encode(PERMIT_TYPEHASH, spender, tokenId, nonce, deadline));
        assembly ("memory-safe") {
            let fmp := mload(0x40)
            mstore(fmp, PERMIT_TYPEHASH)
            mstore(add(fmp, 0x20), spender)
            mstore(add(fmp, 0x40), tokenId)
            mstore(add(fmp, 0x60), nonce)
            mstore(add(fmp, 0x80), deadline)
            digest := keccak256(fmp, 0xa0)
        }
    }

    function hashPermitForAll(address operator, bool approved, uint256 nonce, uint256 deadline)
        internal
        pure
        returns (bytes32 digest)
    {
        // equivalent to: keccak256(abi.encode(PERMIT_FOR_ALL_TYPEHASH, operator, approved, nonce, deadline));
        assembly ("memory-safe") {
            let fmp := mload(0x40)
            mstore(fmp, PERMIT_FOR_ALL_TYPEHASH)
            mstore(add(fmp, 0x20), operator)
            mstore(add(fmp, 0x40), approved)
            mstore(add(fmp, 0x60), nonce)
            mstore(add(fmp, 0x80), deadline)
            digest := keccak256(fmp, 0xa0)
        }
    }
}
