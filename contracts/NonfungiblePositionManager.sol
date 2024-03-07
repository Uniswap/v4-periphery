// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {ERC721} from "openzeppelin-contracts/contracts/token/ERC721/ERC721.sol";
import {INonfungiblePositionManager} from "./interfaces/INonfungiblePositionManager.sol";
import {BaseLiquidityManagement} from "./base/BaseLiquidityManagement.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {LiquidityPosition, LiquidityPositionIdLibrary} from "./types/LiquidityPositionId.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";

import {LiquidityAmounts} from "./libraries/LiquidityAmounts.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

contract NonfungiblePositionManager is BaseLiquidityManagement, INonfungiblePositionManager, ERC721 {
    using PoolIdLibrary for PoolKey;
    using LiquidityPositionIdLibrary for LiquidityPosition;
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
        require(params.amount0Min <= uint256(uint128(delta.amount0())), "INSUFFICIENT_AMOUNT0");
        require(params.amount1Min <= uint256(uint128(delta.amount1())), "INSUFFICIENT_AMOUNT1");
    }

    function decreaseLiquidity(DecreaseLiquidityParams memory params, bytes calldata hookData)
        public
        isAuthorizedForToken(params.tokenId)
        returns (BalanceDelta delta)
    {
        require(params.liquidityDelta != 0, "Must decrease liquidity");
        Position storage position = positions[params.tokenId];
        delta = BaseLiquidityManagement.modifyLiquidity(
            position.position.key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: position.position.tickLower,
                tickUpper: position.position.tickUpper,
                liquidityDelta: -int256(uint256(params.liquidityDelta))
            }),
            hookData,
            ownerOf(params.tokenId)
        );
        require(params.amount0Min <= uint256(uint128(-delta.amount0())), "INSUFFICIENT_AMOUNT0");
        require(params.amount1Min <= uint256(uint128(-delta.amount1())), "INSUFFICIENT_AMOUNT1");

        // position.tokensOwed0 +=
        //     uint128(amount0) +
        //     uint128(
        //         FullMath.mulDiv(
        //             feeGrowthInside0LastX128 - position.feeGrowthInside0LastX128,
        //             positionLiquidity,
        //             FixedPoint128.Q128
        //         )
        //     );
        // position.tokensOwed1 +=
        //     uint128(amount1) +
        //     uint128(
        //         FullMath.mulDiv(
        //             feeGrowthInside1LastX128 - position.feeGrowthInside1LastX128,
        //             positionLiquidity,
        //             FixedPoint128.Q128
        //         )
        //     );

        // position.feeGrowthInside0LastX128 = feeGrowthInside0LastX128;
        // position.feeGrowthInside1LastX128 = feeGrowthInside1LastX128;

        // update the position
        position.liquidity -= params.liquidityDelta;
    }

    function burn(uint256 tokenId, bytes calldata hookData)
        external
        isAuthorizedForToken(tokenId)
        returns (BalanceDelta delta)
    {
        // remove liquidity
        Position storage position = positions[tokenId];
        if (0 < position.liquidity) {
            decreaseLiquidity(
                DecreaseLiquidityParams({
                    tokenId: tokenId,
                    liquidityDelta: position.liquidity,
                    amount0Min: 0,
                    amount1Min: 0,
                    deadline: block.timestamp
                }),
                hookData
            );
        }

        require(position.tokensOwed0 == 0 && position.tokensOwed1 == 0, "NOT_EMPTY");
        delete positions[tokenId];

        // burn the token
        _burn(tokenId);
    }

    // TODO: in v3, we can partially collect fees, but what was the usecase here?
    function collect(uint256 tokenId, address recipient) external {}

    function _afterTokenTransfer(address from, address to, uint256 firstTokenId, uint256 batchSize) internal override {
        Position storage position = positions[firstTokenId];
        position.operator = address(0x0);
        liquidityOf[from][position.position.toId()] -= position.liquidity;
        liquidityOf[to][position.position.toId()] += position.liquidity;
    }

    modifier isAuthorizedForToken(uint256 tokenId) {
        require(_isApprovedOrOwner(msg.sender, tokenId), "Not approved");
        _;
    }
}
