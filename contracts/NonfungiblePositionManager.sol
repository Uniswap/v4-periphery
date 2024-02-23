// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {ERC721} from "openzeppelin-contracts/contracts/token/ERC721/ERC721.sol";

contract NonfungiblePositionManager is ERC721 {
    constructor() ERC721("Uniswap V4 LPT", "UV4LPT") {}
}