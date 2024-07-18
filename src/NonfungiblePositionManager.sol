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

import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
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
    function modifyLiquidities(bytes calldata unlockData, uint256 deadline)
        external
        checkDeadline(deadline)
        returns (bytes[] memory)
    {
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
                returnData[i] = _increase(params[i], sender);
            } else if (actions[i] == Actions.DECREASE) {
                returnData[i] = _decrease(params[i], sender);
            } else if (actions[i] == Actions.MINT) {
                returnData[i] = _mint(params[i]);
            } else if (actions[i] == Actions.CLOSE_CURRENCY) {
                returnData[i] = _close(params[i], sender);
            } else if (actions[i] == Actions.BURN) {
                // TODO: Burn will just be moved outside of this.. or coupled with a decrease..
                (uint256 tokenId) = abi.decode(params[i], (uint256));
                burn(tokenId, sender);
            } else {
                revert UnsupportedAction();
            }
        }
    }

    /// @param param is an encoding of uint256 tokenId, uint256 liquidity, bytes hookData
    /// @param sender the msg.sender, set by the `modifyLiquidities` function before the `unlockCallback`. Using msg.sender directly inside
    /// the _unlockCallback will be the pool manager.
    /// @return returns an encoding of the BalanceDelta applied by this increase call, including credited fees.
    /// @dev Calling increase with 0 liquidity will credit the caller with any underlying fees of the position
    function _increase(bytes memory param, address sender) internal returns (bytes memory) {
        (uint256 tokenId, uint256 liquidity, bytes memory hookData) = abi.decode(param, (uint256, uint256, bytes));

        _requireApprovedOrOwner(tokenId, sender);

        TokenPosition memory tokenPos = tokenPositions[tokenId];
        // Note: The tokenId is used as the salt for this position, so every minted liquidity has unique storage in the pool manager.
        (BalanceDelta delta,) = _modifyLiquidity(tokenPos.range, liquidity.toInt256(), bytes32(tokenId), hookData);
        return abi.encode(delta);
    }

    /// @param params is an encoding of uint256 tokenId, uint256 liquidity, bytes hookData
    /// @param sender the msg.sender, set by the `modifyLiquidities` function before the `unlockCallback`. Using msg.sender directly inside
    /// the _unlockCallback will be the pool manager.
    /// @return returns an encoding of the BalanceDelta applied by this increase call, including credited fees.
    /// @dev Calling decrease with 0 liquidity will credit the caller with any underlying fees of the position
    function _decrease(bytes memory params, address sender) internal returns (bytes memory) {
        (uint256 tokenId, uint256 liquidity, bytes memory hookData) = abi.decode(params, (uint256, uint256, bytes));

        _requireApprovedOrOwner(tokenId, sender);

        TokenPosition memory tokenPos = tokenPositions[tokenId];
        // Note: the tokenId is used as the salt.
        (BalanceDelta delta,) = _modifyLiquidity(tokenPos.range, -(liquidity.toInt256()), bytes32(tokenId), hookData);
        return abi.encode(delta);
    }

    function _mint(bytes memory param) internal returns (bytes memory) {
        (LiquidityRange memory range, uint256 liquidity, address owner, bytes memory hookData) =
            abi.decode(param, (LiquidityRange, uint256, address, bytes));

        // mint receipt token
        uint256 tokenId;
        unchecked {
            tokenId = nextTokenId++;
        }
        _mint(owner, tokenId);

        (BalanceDelta delta,) = _modifyLiquidity(range, liquidity.toInt256(), bytes32(tokenId), hookData);

        tokenPositions[tokenId] = TokenPosition({owner: owner, range: range, operator: address(0x0)});
        return abi.encode(delta);
    }

    /// @param params is an encoding of the Currency to close
    /// @param sender is the msg.sender encoded by the `modifyLiquidities` function before the `unlockCallback`.
    /// @return int256 the balance of the currency being settled by this call
    function _close(bytes memory params, address sender) internal returns (bytes memory) {
        (Currency currency) = abi.decode(params, (Currency));
        // this address has applied all deltas on behalf of the user/owner
        // it is safe to close this entire delta because of slippage checks throughout the batched calls.
        int256 currencyDelta = manager.currencyDelta(address(this), currency);

        // the sender is the payer or receiver
        if (currencyDelta < 0) {
            currency.settle(manager, sender, uint256(-int256(currencyDelta)), false);
        } else {
            currency.take(manager, sender, uint256(int256(currencyDelta)), false);
        }

        return abi.encode(currencyDelta);
    }

    function burn(uint256 tokenId, address sender) internal {
        _requireApprovedOrOwner(tokenId, sender);
        // We do not need to enforce the pool manager to be unlocked bc this function is purely clearing storage for the minted tokenId.
        TokenPosition memory tokenPos = tokenPositions[tokenId];
        // Checks that the full position's liquidity has been removed and all tokens have been collected from tokensOwed.
        _validateBurn(tokenPos.owner, tokenPos.range);
        delete tokenPositions[tokenId];
        // Burn the token.
        _burn(tokenId);
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

    function _requireApprovedOrOwner(uint256 tokenId, address sender) internal view {
        if (!_isApprovedOrOwner(sender, tokenId)) revert NotApproved(sender);
    }

    modifier checkDeadline(uint256 deadline) {
        if (block.timestamp > deadline) revert DeadlinePassed();
        _;
    }
}
