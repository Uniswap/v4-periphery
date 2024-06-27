// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {ERC721Permit} from "./base/ERC721Permit.sol";
import {INonfungiblePositionManager} from "./interfaces/INonfungiblePositionManager.sol";
import {BaseLiquidityManagement} from "./base/BaseLiquidityManagement.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {CurrencySettleTake} from "./libraries/CurrencySettleTake.sol";
import {LiquidityRange, LiquidityRangeId, LiquidityRangeIdLibrary} from "./types/LiquidityRange.sol";
import {BalanceDelta, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";

import {LiquidityAmounts} from "./libraries/LiquidityAmounts.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";

contract NonfungiblePositionManager is INonfungiblePositionManager, BaseLiquidityManagement, ERC721Permit {
    using CurrencyLibrary for Currency;
    using CurrencySettleTake for Currency;
    using PoolIdLibrary for PoolKey;
    using LiquidityRangeIdLibrary for LiquidityRange;
    using StateLibrary for IPoolManager;
    using SafeCast for uint256;

    /// @dev The ID of the next token that will be minted. Skips 0
    uint256 private _nextId = 1;

    // maps the ERC721 tokenId to the keys that uniquely identify a liquidity position (owner, range)
    mapping(uint256 tokenId => TokenPosition position) public tokenPositions;

    constructor(IPoolManager _manager)
        BaseLiquidityManagement(_manager)
        ERC721Permit("Uniswap V4 Positions NFT-V1", "UNI-V4-POS", "1")
    {}

    // NOTE: more gas efficient as LiquidityAmounts is used offchain
    // TODO: deadline check
    function mint(
        LiquidityRange calldata range,
        uint256 liquidity,
        uint256 deadline,
        address recipient,
        bytes calldata hookData
    ) public payable returns (uint256 tokenId, BalanceDelta delta) {
        // delta = modifyLiquidity(range, liquidity.toInt256(), hookData, false);
        delta = _lockAndIncreaseLiquidity(msg.sender, range, liquidity, hookData, false);

        // mint receipt token
        _mint(recipient, (tokenId = _nextId++));
        tokenPositions[tokenId] = TokenPosition({owner: msg.sender, range: range});
    }

    // NOTE: more expensive since LiquidityAmounts is used onchain
    // function mint(MintParams calldata params) external payable returns (uint256 tokenId, BalanceDelta delta) {
    //     (uint160 sqrtPriceX96,,,) = manager.getSlot0(params.range.poolKey.toId());
    //     (tokenId, delta) = mint(
    //         params.range,
    //         LiquidityAmounts.getLiquidityForAmounts(
    //             sqrtPriceX96,
    //             TickMath.getSqrtPriceAtTick(params.range.tickLower),
    //             TickMath.getSqrtPriceAtTick(params.range.tickUpper),
    //             params.amount0Desired,
    //             params.amount1Desired
    //         ),
    //         params.deadline,
    //         params.recipient,
    //         params.hookData
    //     );
    //     require(params.amount0Min <= uint256(uint128(delta.amount0())), "INSUFFICIENT_AMOUNT0");
    //     require(params.amount1Min <= uint256(uint128(delta.amount1())), "INSUFFICIENT_AMOUNT1");
    // }

    function increaseLiquidity(uint256 tokenId, uint256 liquidity, bytes calldata hookData, bool claims)
        external
        isAuthorizedForToken(tokenId)
        returns (BalanceDelta delta)
    {
        TokenPosition memory tokenPos = tokenPositions[tokenId];
        delta = _lockAndIncreaseLiquidity(tokenPos.owner, tokenPos.range, liquidity, hookData, claims);
    }

    function decreaseLiquidity(uint256 tokenId, uint256 liquidity, bytes calldata hookData, bool claims)
        public
        isAuthorizedForToken(tokenId)
        returns (BalanceDelta delta, BalanceDelta thisDelta)
    {
        TokenPosition memory tokenPos = tokenPositions[tokenId];
        (delta, thisDelta) = _lockAndDecreaseLiquidity(tokenPos.owner, tokenPos.range, liquidity, hookData, claims);
    }

    function burn(uint256 tokenId, address recipient, bytes calldata hookData, bool claims)
        external
        isAuthorizedForToken(tokenId)
        returns (BalanceDelta delta)
    {
        // remove liquidity
        TokenPosition storage tokenPosition = tokenPositions[tokenId];
        LiquidityRangeId rangeId = tokenPosition.range.toId();
        Position storage position = positions[msg.sender][rangeId];
        if (0 < position.liquidity) {
            (delta,) = decreaseLiquidity(tokenId, position.liquidity, hookData, claims);
            (delta) = collect(tokenId, recipient, hookData, claims);
        }
        require(position.tokensOwed0 == 0 && position.tokensOwed1 == 0, "NOT_EMPTY");
        delete positions[msg.sender][rangeId];
        delete tokenPositions[tokenId];

        // burn the token
        _burn(tokenId);
    }

    // TODO: in v3, we can partially collect fees, but what was the usecase here?
    function collect(uint256 tokenId, address recipient, bytes calldata hookData, bool claims)
        public
        returns (BalanceDelta delta)
    {
        TokenPosition memory tokenPos = tokenPositions[tokenId];
        delta = _lockAndCollect(tokenPos.owner, tokenPos.range, hookData, claims);
    }

    function feesOwed(uint256 tokenId) external view returns (uint256 token0Owed, uint256 token1Owed) {
        TokenPosition memory tokenPosition = tokenPositions[tokenId];
        return feesOwed(tokenPosition.owner, tokenPosition.range);
    }

    function _beforeTokenTransfer(address from, address to, uint256 tokenId) internal override {
        TokenPosition storage tokenPosition = tokenPositions[tokenId];
        LiquidityRangeId rangeId = tokenPosition.range.toId();
        Position storage position = positions[from][rangeId];
        position.operator = address(0x0);

        // transfer position data to destination
        positions[to][rangeId] = position;
        delete positions[from][rangeId];

        // update token position
        tokenPositions[tokenId] = TokenPosition({owner: to, range: tokenPosition.range});
    }

    function _getAndIncrementNonce(uint256 tokenId) internal override returns (uint256) {
        TokenPosition memory tokenPosition = tokenPositions[tokenId];
        return uint256(positions[tokenPosition.owner][tokenPosition.range.toId()].nonce++);
    }

    modifier isAuthorizedForToken(uint256 tokenId) {
        require(_isApprovedOrOwner(msg.sender, tokenId), "Not approved");
        _;
    }
}
