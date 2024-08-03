// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.20;

import {ERC721Permit} from "../../src/base/ERC721Permit.sol";

contract MockERC721Permit is ERC721Permit {
    uint256 public lastTokenId;

    constructor(string memory name, string memory symbol, string memory version) ERC721Permit(name, symbol, version) {}

    function tokenURI(uint256) public pure override returns (string memory) {
        return "";
    }

    function mint() external returns (uint256 tokenId) {
        tokenId = ++lastTokenId;
        _mint(msg.sender, tokenId);
    }
}
