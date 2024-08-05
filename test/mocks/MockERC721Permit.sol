// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.20;

import {ERC721Permit_v4} from "../../src/base/ERC721Permit_v4.sol";

contract MockERC721Permit is ERC721Permit_v4 {
    uint256 public lastTokenId;

    constructor(string memory name, string memory symbol) ERC721Permit_v4(name, symbol) {}

    function mint() external returns (uint256 tokenId) {
        tokenId = ++lastTokenId;
        _mint(msg.sender, tokenId);
    }
}
