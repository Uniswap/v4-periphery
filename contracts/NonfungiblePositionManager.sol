// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";

contract NonfungiblePositionManager is ERC721 {
    constructor() ERC721("Uniswap V4 Positions NFT-V1", "UNI-V4-POS") {}
}
