// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {ERC721Permit} from "./base/ERC721Permit.sol";
import {INonfungiblePositionManager, Actions} from "./interfaces/INonfungiblePositionManager.sol";
import {SafeCallback} from "./base/SafeCallback.sol";
import {ImmutableState} from "./base/ImmutableState.sol";

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

contract NonfungiblePositionManager is INonfungiblePositionManager, ERC721Permit, SafeCallback {
    using CurrencyLibrary for Currency;
    using CurrencySettleTake for Currency;
    using PoolIdLibrary for PoolKey;
    using LiquidityRangeIdLibrary for LiquidityRange;
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;
    using SafeCast for uint256;

    /// @dev The ID of the next token that will be minted. Skips 0
    uint256 public nextTokenId = 1;

    // maps the ERC721 tokenId to its Range (poolKey, tick range)
    mapping(uint256 tokenId => LiquidityRange range) public tokenRange;

    constructor(IPoolManager _manager)
        ImmutableState(_manager)
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

        tokenRange[tokenId] = range;
    }

    // Note: Calling increase with 0 will accrue any underlying fees.
    function increaseLiquidity(uint256 tokenId, uint256 liquidity, bytes memory hookData, address sender)
        internal
        isAuthorizedForToken(tokenId, sender)
        returns (BalanceDelta delta)
    {
        // Note: The tokenId is used as the salt for this position, so every minted liquidity has unique storage in the pool manager.
        (delta,) = _modifyLiquidity(tokenRange[tokenId], liquidity.toInt256(), bytes32(tokenId), hookData);
    }

    // Note: Calling decrease with 0 will accrue any underlying fees.
    function decreaseLiquidity(uint256 tokenId, uint256 liquidity, bytes memory hookData, address sender)
        internal
        isAuthorizedForToken(tokenId, sender)
        returns (BalanceDelta delta)
    {
        (delta,) = _modifyLiquidity(tokenRange[tokenId], -(liquidity.toInt256()), bytes32(tokenId), hookData);
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

        // Checks that the full position's liquidity has been removed and all tokens have been collected from tokensOwed.
        _validateBurn(tokenId);

        delete tokenRange[tokenId];
        // Burn the token.
        _burn(tokenId);
    }

    function _modifyLiquidity(LiquidityRange memory range, int256 liquidityChange, bytes32 salt, bytes memory hookData)
        internal
        returns (BalanceDelta liquidityDelta, BalanceDelta totalFeesAccrued)
    {
        (liquidityDelta, totalFeesAccrued) = manager.modifyLiquidity(
            range.poolKey,
            IPoolManager.ModifyLiquidityParams({
                tickLower: range.tickLower,
                tickUpper: range.tickUpper,
                liquidityDelta: liquidityChange,
                salt: salt
            }),
            hookData
        );
    }

    function _validateBurn(uint256 tokenId) internal {
        bytes32 positionId = getPositionIdFromTokenId(tokenId);
        uint128 liquidity = manager.getPositionLiquidity(tokenRange[tokenId].poolKey.toId(), positionId);
        if (liquidity > 0) revert PositionMustBeEmpty();
    }

    function getPositionIdFromTokenId(uint256 tokenId) public view returns (bytes32 positionId) {
        LiquidityRange memory range = tokenRange[tokenId];
        bytes32 salt = bytes32(tokenId);
        int24 tickLower = range.tickLower;
        int24 tickUpper = range.tickUpper;
        address owner = address(this);

        // TODO: reorganize this into library on core?
        // positionId = keccak256(abi.encodePacked(owner, tickLower, tickUpper, salt))
        /// @solidity memory-safe-assembly
        assembly {
            mstore(0x26, salt) // [0x26, 0x46)
            mstore(0x06, tickUpper) // [0x23, 0x26)
            mstore(0x03, tickLower) // [0x20, 0x23)
            mstore(0, owner) // [0x0c, 0x20)
            positionId := keccak256(0x0c, 0x3a) // len is 58 bytes
            mstore(0x26, 0) // rewrite 0x26 to 0
        }
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
