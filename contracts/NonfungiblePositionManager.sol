// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {ERC721Permit} from "./base/ERC721Permit.sol";
import {INonfungiblePositionManager, Actions} from "./interfaces/INonfungiblePositionManager.sol";
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
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import {TransientLiquidityDelta} from "./libraries/TransientLiquidityDelta.sol";

import "forge-std/console2.sol";

contract NonfungiblePositionManager is INonfungiblePositionManager, BaseLiquidityManagement, ERC721Permit {
    using CurrencyLibrary for Currency;
    using CurrencySettleTake for Currency;
    using PoolIdLibrary for PoolKey;
    using LiquidityRangeIdLibrary for LiquidityRange;
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;
    using SafeCast for uint256;
    using TransientLiquidityDelta for Currency;

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

        (Actions[] memory actions, bytes[] memory params, Currency[] memory currencies) =
            abi.decode(unlockData, (Actions[], bytes[], Currency[]));

        bytes[] memory returnData = _dispatch(actions, params, sender);

        for (uint256 i; i < currencies.length; i++) {
            currencies[i].close(manager, sender, false); // TODO: support claims
            currencies[i].close(manager, address(this), true); // position manager always takes 6909
        }

        return abi.encode(returnData);
    }

    function _dispatch(Actions[] memory actions, bytes[] memory params, address sender)
        internal
        returns (bytes[] memory returnData)
    {
        returnData = new bytes[](actions.length);

        for (uint256 i; i < actions.length; i++) {
            if (actions[i] == Actions.INCREASE) {
                (uint256 tokenId, uint256 liquidity, bytes memory hookData, bool claims) =
                    abi.decode(params[i], (uint256, uint256, bytes, bool));
                returnData[i] = abi.encode(increaseLiquidity(tokenId, liquidity, hookData, claims, sender));
            } else if (actions[i] == Actions.DECREASE) {
                (uint256 tokenId, uint256 liquidity, bytes memory hookData, bool claims) =
                    abi.decode(params[i], (uint256, uint256, bytes, bool));
                returnData[i] = abi.encode(decreaseLiquidity(tokenId, liquidity, hookData, claims, sender));
            } else if (actions[i] == Actions.MINT) {
                (LiquidityRange memory range, uint256 liquidity, uint256 deadline, address owner, bytes memory hookData)
                = abi.decode(params[i], (LiquidityRange, uint256, uint256, address, bytes));
                (BalanceDelta delta, uint256 tokenId) = mint(range, liquidity, deadline, owner, hookData, sender);
                returnData[i] = abi.encode(delta, tokenId);
            } else if (actions[i] == Actions.BURN) {
                (uint256 tokenId) = abi.decode(params[i], (uint256));
                burn(tokenId, sender);
            } else if (actions[i] == Actions.COLLECT) {
                (uint256 tokenId, address recipient, bytes memory hookData, bool claims) =
                    abi.decode(params[i], (uint256, address, bytes, bool));
                returnData[i] = abi.encode(collect(tokenId, recipient, hookData, claims, sender));
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
        bytes memory hookData,
        address sender
    ) internal checkDeadline(deadline) returns (BalanceDelta delta, uint256 tokenId) {
        delta = _increaseLiquidity(owner, range, liquidity, hookData, sender);

        // mint receipt token
        _mint(owner, (tokenId = nextTokenId++));
        tokenPositions[tokenId] = TokenPosition({owner: owner, range: range});
    }

    function increaseLiquidity(uint256 tokenId, uint256 liquidity, bytes memory hookData, bool claims, address sender)
        internal
        isAuthorizedForToken(tokenId, sender)
        returns (BalanceDelta delta)
    {
        TokenPosition memory tokenPos = tokenPositions[tokenId];

        delta = _increaseLiquidity(tokenPos.owner, tokenPos.range, liquidity, hookData, sender);
    }

    function decreaseLiquidity(uint256 tokenId, uint256 liquidity, bytes memory hookData, bool claims, address sender)
        internal
        isAuthorizedForToken(tokenId, sender)
        returns (BalanceDelta delta)
    {
        TokenPosition memory tokenPos = tokenPositions[tokenId];

        delta = _decreaseLiquidity(tokenPos.owner, tokenPos.range, liquidity, hookData);
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

    function collect(uint256 tokenId, address recipient, bytes memory hookData, bool claims, address sender)
        internal
        isAuthorizedForToken(tokenId, sender)
        returns (BalanceDelta delta)
    {
        TokenPosition memory tokenPos = tokenPositions[tokenId];

        delta = _collect(recipient, tokenPos.owner, tokenPos.range, hookData, sender);
    }

    function feesOwed(uint256 tokenId) external view returns (uint256 token0Owed, uint256 token1Owed) {
        TokenPosition memory tokenPosition = tokenPositions[tokenId];
        return feesOwed(tokenPosition.owner, tokenPosition.range);
    }

    // TODO: Bug - Positions are overrideable unless we can allow two of the same users to have distinct positions.
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

    modifier isAuthorizedForToken(uint256 tokenId, address sender) {
        require(_isApprovedOrOwner(sender, tokenId), "Not approved");
        _;
    }

    modifier checkDeadline(uint256 deadline) {
        if (block.timestamp > deadline) revert DeadlinePassed();
        _;
    }
}
