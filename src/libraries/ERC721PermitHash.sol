// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

library ERC721PermitHashLibrary {
    /// @dev Value is equal to keccak256("Permit(address spender,uint256 tokenId,uint256 nonce,uint256 deadline)");
    bytes32 constant PERMIT_TYPEHASH = 0x49ecf333e5b8c95c40fdafc95c1ad136e8914a8fb55e9dc8bb01eaa83a2df9ad;

    function hash(address spender, uint256 tokenId, uint256 nonce, uint256 deadline) internal pure returns (bytes32) {
        return keccak256(abi.encode(PERMIT_TYPEHASH, spender, tokenId, nonce, deadline));
    }
}
