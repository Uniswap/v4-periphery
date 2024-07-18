// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {ERC721Permit} from "./base/ERC721Permit.sol";
import {INonfungiblePositionManager, Actions} from "./interfaces/INonfungiblePositionManager.sol";
import {BaseLiquidityManagement} from "./base/BaseLiquidityManagement.sol";
import {Multicall} from "./base/Multicall.sol";
import {PoolInitializer} from "./base/PoolInitializer.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {CurrencySettleTake} from "./libraries/CurrencySettleTake.sol";
import {LiquidityRange, LiquidityRangeId, LiquidityRangeIdLibrary} from "./types/LiquidityRange.sol";
import {BalanceDelta, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";

import {LiquidityAmounts} from "./libraries/LiquidityAmounts.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {FixedPoint128} from "@uniswap/v4-core/src/libraries/FixedPoint128.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";

contract NonfungiblePositionManager is
    INonfungiblePositionManager,
    BaseLiquidityManagement,
    ERC721Permit,
    PoolInitializer,
    Multicall
{
    using CurrencyLibrary for Currency;
    using CurrencySettleTake for Currency;
    using PoolIdLibrary for PoolKey;
    using LiquidityRangeIdLibrary for LiquidityRange;
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;
    using SafeCast for uint256;

    /// @dev The ID of the next token that will be minted. Skips 0
    uint256 public nextTokenId = 1;

    // maps the ERC721 tokenId to the keys that uniquely identify a liquidity position (owner, range)
    mapping(uint256 tokenId => TokenPosition position) public tokenPositions;

    constructor(IPoolManager _manager)
        BaseLiquidityManagement(_manager)
        ERC721Permit("Uniswap V4 Positions NFT-V1", "UNI-V4-POS", "1")
    {}

    /// @param unlockData is an encoding of actions, params, and currencies
    /// @return returnData is the endocing of each actions return information
    function modifyLiquidities(bytes calldata unlockData) public returns (bytes[] memory) {
        // TODO: Edit the encoding/decoding.
        return abi.decode(manager.unlock(abi.encode(unlockData, msg.sender)), (bytes[]));
    }

    function _unlockCallback(bytes calldata payload) internal override returns (bytes memory) {
        // TODO: Fix double encode/decode
        (bytes memory unlockData, address sender) = abi.decode(payload, (bytes, address));

        (Actions[] memory actions, bytes[] memory params) = abi.decode(unlockData, (Actions[], bytes[]));

        bytes[] memory returnData = _dispatch(actions, params, sender);

        return abi.encode(returnData);
    }

    function _dispatch(Actions[] memory actions, bytes[] memory params, address sender)
        internal
        returns (bytes[] memory returnData)
    {
        if (actions.length != params.length) revert MismatchedLengths();

        returnData = new bytes[](actions.length);
        for (uint256 i; i < actions.length; i++) {
            if (actions[i] == Actions.INCREASE) {
                (uint256 tokenId, uint256 liquidity, bytes memory hookData) =
                    abi.decode(params[i], (uint256, uint256, bytes));
                returnData[i] = abi.encode(increaseLiquidity(tokenId, liquidity, hookData, sender));
            } else if (actions[i] == Actions.DECREASE) {
                (uint256 tokenId, uint256 liquidity, bytes memory hookData) =
                    abi.decode(params[i], (uint256, uint256, bytes));
                returnData[i] = abi.encode(decreaseLiquidity(tokenId, liquidity, hookData, sender));
            } else if (actions[i] == Actions.MINT) {
                (LiquidityRange memory range, uint256 liquidity, uint256 deadline, address owner, bytes memory hookData)
                = abi.decode(params[i], (LiquidityRange, uint256, uint256, address, bytes));
                returnData[i] = abi.encode(mint(range, liquidity, deadline, owner, hookData));
            } else if (actions[i] == Actions.CLOSE_CURRENCY) {
                (Currency currency) = abi.decode(params[i], (Currency));
                returnData[i] = abi.encode(close(currency, sender));
            } else if (actions[i] == Actions.BURN) {
                (uint256 tokenId) = abi.decode(params[i], (uint256));
                burn(tokenId, sender);
            } else {
                revert UnsupportedAction();
            }
        }
    }

    function mint(
        LiquidityRange memory range,
        uint256 liquidity,
        uint256 deadline,
        address owner,
        bytes memory hookData
    ) internal checkDeadline(deadline) returns (BalanceDelta delta) {
        // mint receipt token
        uint256 tokenId;
        unchecked {
            tokenId = nextTokenId++;
        }
        _mint(owner, tokenId);

        (delta,) = _modifyLiquidity(range, liquidity.toInt256(), bytes32(tokenId), hookData);

        tokenPositions[tokenId] = TokenPosition({owner: owner, range: range, operator: address(0x0)});
    }

    // Note: Calling increase with 0 will accrue any underlying fees.
    function increaseLiquidity(uint256 tokenId, uint256 liquidity, bytes memory hookData, address sender)
        internal
        isAuthorizedForToken(tokenId, sender)
        returns (BalanceDelta delta)
    {
        TokenPosition memory tokenPos = tokenPositions[tokenId];
        // Note: The tokenId is used as the salt for this position, so every minted liquidity has unique storage in the pool manager.
        (delta,) = _modifyLiquidity(tokenPos.range, liquidity.toInt256(), bytes32(tokenId), hookData);
    }

    // Note: Calling decrease with 0 will accrue any underlying fees.
    function decreaseLiquidity(uint256 tokenId, uint256 liquidity, bytes memory hookData, address sender)
        internal
        isAuthorizedForToken(tokenId, sender)
        returns (BalanceDelta delta)
    {
        TokenPosition memory tokenPos = tokenPositions[tokenId];
        (delta,) = _modifyLiquidity(tokenPos.range, -(liquidity.toInt256()), bytes32(tokenId), hookData);
    }

    // there is no authorization scheme because the payer/recipient is always the sender
    // TODO: Add more advanced functionality for other payers/recipients, needs auth scheme.
    function close(Currency currency, address sender) internal returns (int256 currencyDelta) {
        // this address has applied all deltas on behalf of the user/owner
        // it is safe to close this entire delta because of slippage checks throughout the batched calls.
        currencyDelta = manager.currencyDelta(address(this), currency);

        // the sender is the payer or receiver
        if (currencyDelta < 0) {
            currency.settle(manager, sender, uint256(-int256(currencyDelta)), false);
        } else {
            currency.take(manager, sender, uint256(int256(currencyDelta)), false);
        }
    }

    function burn(uint256 tokenId, address sender) internal isAuthorizedForToken(tokenId, sender) {
        // We do not need to enforce the pool manager to be unlocked bc this function is purely clearing storage for the minted tokenId.
        TokenPosition memory tokenPos = tokenPositions[tokenId];
        // Checks that the full position's liquidity has been removed and all tokens have been collected from tokensOwed.
        _validateBurn(tokenPos.owner, tokenPos.range);
        delete tokenPositions[tokenId];
        // Burn the token.
        _burn(tokenId);
    }

    function feesOwed(uint256 tokenId) external view returns (BalanceDelta feesAccrued) {
        TokenPosition memory tokenPos = tokenPositions[tokenId];
        (uint256 feeGrowthInside0X128, uint256 feeGrowthInside1X128) = manager.getFeeGrowthInside(
            tokenPos.range.poolKey.toId(), tokenPos.range.tickLower, tokenPos.range.tickUpper
        );

        // TODO: optimize
        bytes32 positionId = keccak256(
            abi.encodePacked(address(this), tokenPos.range.tickLower, tokenPos.range.tickUpper, bytes32(tokenId))
        );

        (uint128 liquidity, uint256 feeGrowthInside0LastX128, uint256 feeGrowthInside1LastX128) =
            manager.getPositionInfo(tokenPos.range.poolKey.toId(), positionId);

        feesAccrued = toBalanceDelta(
            int128(getFeeOwed(feeGrowthInside0X128, feeGrowthInside0LastX128, liquidity)),
            int128(getFeeOwed(feeGrowthInside1X128, feeGrowthInside1LastX128, liquidity))
        );
    }

    function getFeeOwed(uint256 feeGrowthInsideX128, uint256 feeGrowthInsideLastX128, uint256 liquidity)
        internal
        pure
        returns (uint128 tokenOwed)
    {
        tokenOwed =
            (FullMath.mulDiv(feeGrowthInsideX128 - feeGrowthInsideLastX128, liquidity, FixedPoint128.Q128)).toUint128();
    }

    // TODO: Bug - Positions are overrideable unless we can allow two of the same users to have distinct positions.
    function _beforeTokenTransfer(address from, address to, uint256 tokenId) internal override {
        TokenPosition storage tokenPosition = tokenPositions[tokenId];
        LiquidityRangeId rangeId = tokenPosition.range.toId();
        Position storage position = positions[from][rangeId];

        // transfer position data to destination
        positions[to][rangeId] = position;
        delete positions[from][rangeId];

        // update token position
        tokenPositions[tokenId] = TokenPosition({owner: to, range: tokenPosition.range, operator: address(0x0)});
    }

    // override ERC721 approval by setting operator
    function _approve(address spender, uint256 tokenId) internal override {
        tokenPositions[tokenId].operator = spender;
    }

    function getApproved(uint256 tokenId) public view override returns (address) {
        require(_exists(tokenId), "ERC721: approved query for nonexistent token");

        return tokenPositions[tokenId].operator;
    }

    modifier isAuthorizedForToken(uint256 tokenId, address sender) {
        require(_isApprovedOrOwner(sender, tokenId), "Not approved");
        _;
    }

    modifier checkDeadline(uint256 deadline) {
        if (block.timestamp > deadline) revert DeadlinePassed();
        _;
    }
}
