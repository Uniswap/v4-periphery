// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {ERC721} from "openzeppelin-contracts/contracts/token/ERC721/ERC721.sol";
import {INonfungiblePositionManager} from "./interfaces/INonfungiblePositionManager.sol";
import {BaseLiquidityManagement} from "./base/BaseLiquidityManagement.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {LiquidityPosition} from "./types/LiquidityPositionId.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";

import {LiquidityAmounts} from "./libraries/LiquidityAmounts.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

contract NonfungiblePositionManager is BaseLiquidityManagement, INonfungiblePositionManager, ERC721 {
    using PoolIdLibrary for PoolKey;
    /// @dev The ID of the next token that will be minted. Skips 0

    uint256 private _nextId = 1;

    constructor(IPoolManager _poolManager) BaseLiquidityManagement(_poolManager) ERC721("Uniswap V4 LP", "LPT") {}

    // details about the uniswap position
    struct Position {
        // the nonce for permits
        uint96 nonce;
        // the address that is approved for spending this token
        address operator;
        LiquidityPosition position;
        // the liquidity of the position
        // NOTE: this value will be less than BaseLiquidityManagement.liquidityOf, if the user
        // owns multiple positions with the same range
        uint128 liquidity;
        // the fee growth of the aggregate position as of the last action on the individual position
        uint256 feeGrowthInside0LastX128;
        uint256 feeGrowthInside1LastX128;
        // how many uncollected tokens are owed to the position, as of the last computation
        uint128 tokensOwed0;
        uint128 tokensOwed1;
    }

    mapping(uint256 tokenId => Position position) public positions;

    // NOTE: more gas efficient as LiquidityAmounts is used offchain
    // TODO: deadline check
    function mint(
        LiquidityPosition calldata position,
        uint256 liquidity,
        uint256 deadline,
        address recipient,
        bytes calldata hookData
    ) public payable returns (uint256 tokenId, BalanceDelta delta) {
        delta = BaseLiquidityManagement.modifyLiquidity(
            position.key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: position.tickLower,
                tickUpper: position.tickUpper,
                liquidityDelta: int256(liquidity)
            }),
            hookData,
            recipient
        );

        // mint receipt token
        // GAS: uncheck this mf
        _mint(recipient, (tokenId = _nextId++));

        positions[tokenId] = Position({
            nonce: 0,
            operator: address(0),
            position: position,
            liquidity: uint128(liquidity),
            feeGrowthInside0LastX128: 0, // TODO:
            feeGrowthInside1LastX128: 0, // TODO:
            tokensOwed0: 0,
            tokensOwed1: 0
        });

        // TODO: event
    }

    // NOTE: more expensive since LiquidityAmounts is used onchain
    function mint(MintParams calldata params) external payable returns (uint256 tokenId, BalanceDelta delta) {
        (uint160 sqrtPriceX96,,) = poolManager.getSlot0(params.position.key.toId());
        (tokenId, delta) = mint(
            params.position,
            LiquidityAmounts.getLiquidityForAmounts(
                sqrtPriceX96,
                TickMath.getSqrtRatioAtTick(params.position.tickLower),
                TickMath.getSqrtRatioAtTick(params.position.tickUpper),
                params.amount0Desired,
                params.amount1Desired
            ),
            params.deadline,
            params.recipient,
            params.hookData
        );
    }

    function burn(uint256 tokenId) external {}

    // TODO: in v3, we can partially collect fees, but what was the usecase here?
    function collect(uint256 tokenId, address recipient) external {}
}
