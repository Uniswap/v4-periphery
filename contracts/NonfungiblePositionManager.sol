// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "./base/PeripheryImmutableState.sol";
import "./base/PeripheryValidation.sol";
import "./interfaces/INonfungiblePositionManager.sol";

contract NonfungiblePositionManager is
    ERC721,
    PeripheryImmutableState,
    INonfungiblePositionManager,
    PeripheryValidation
{
    constructor(address _poolManager, address _WETH9)
        ERC721("Uniswap V4 Positions NFT-V1", "UNI-V4-POS")
        PeripheryImmutableState(_poolManager, _WETH9)
    {}

    function mint(MintParams calldata params)
        external
        payable
        override
        checkDeadline(params.deadline)
        returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1)
    {}
}
