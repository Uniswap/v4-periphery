// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {ERC721} from "openzeppelin-contracts/contracts/token/ERC721/ERC721.sol";
import {INonfungiblePositionManager} from "./interfaces/INonfungiblePositionManager.sol";
import {BaseLiquidityManagement} from "./base/BaseLiquidityManagement.sol";

import {IPoolManager} from "@uniswap/v4-core/contracts/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/contracts/types/PoolKey.sol";
import {LiquidityPosition} from "./types/LiquidityPositionId.sol";

contract NonfungiblePositionManager is BaseLiquidityManagement, INonfungiblePositionManager, ERC721 {
    constructor(IPoolManager _poolManager) BaseLiquidityManagement(_poolManager) ERC721("Uniswap V4 LP", "LPT") {}

    // NOTE: more gas efficient as LiquidityAmounts is used offchain
    function mint(LiquidityPosition memory position, uint256 liquidity, uint256 deadline)
        external
        payable
        returns (uint256 tokenId)
    {}

    // NOTE: more expensive since LiquidityAmounts is used onchain
    function mint(
        PoolKey memory key,
        uint256 amount0Desired,
        uint256 amount1Desired,
        uint256 amount0Min,
        uint256 amount1Min,
        address recipient,
        uint256 deadline
    ) external payable returns (uint256 tokenId) {}

    function burn(uint256 tokenId) external {}

    // TODO: in v3, we can partially collect fees, but what was the usecase here?
    function collect(uint256 tokenId, address recipient) external {}
}
