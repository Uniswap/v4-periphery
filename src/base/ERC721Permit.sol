// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import {ERC721} from "solmate/src/tokens/ERC721.sol";

/// @notice An ERC721 contract that supports permit.
/// TODO: Support permit.
contract ERC721Permit is ERC721 {
    constructor(string memory name_, string memory symbol_, string memory version_) ERC721(name_, symbol_) {}

    function _isApprovedOrOwner(address spender, uint256 tokenId) internal view returns (bool) {
        return spender == ownerOf(tokenId) || getApproved[tokenId] == spender
            || isApprovedForAll[ownerOf(tokenId)][spender];
    }

    // TODO: Use PositionDescriptor.
    function tokenURI(uint256 id) public pure override returns (string memory) {
        return string(abi.encode(id));
    }
}
