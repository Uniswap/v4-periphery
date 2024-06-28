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
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import {TransientLiquidityDelta} from "./libraries/TransientLiquidityDelta.sol";

contract NonfungiblePositionManager is INonfungiblePositionManager, BaseLiquidityManagement, ERC721Permit {
    using CurrencyLibrary for Currency;
    using CurrencySettleTake for Currency;
    using PoolIdLibrary for PoolKey;
    using LiquidityRangeIdLibrary for LiquidityRange;
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;
    using SafeCast for uint256;
    using TransientLiquidityDelta for address;

    /// @dev The ID of the next token that will be minted. Skips 0
    uint256 private _nextId = 1;

    // maps the ERC721 tokenId to the keys that uniquely identify a liquidity position (owner, range)
    mapping(uint256 tokenId => TokenPosition position) public tokenPositions;

    constructor(IPoolManager _manager)
        BaseLiquidityManagement(_manager)
        ERC721Permit("Uniswap V4 Positions NFT-V1", "UNI-V4-POS", "1")
    {}

    function unlockAndExecute(bytes[] memory data) public returns (bytes memory) {
        return manager.unlock(abi.encode(data));
    }

    function _unlockCallback(bytes calldata payload) internal override returns (bytes memory) {
        bytes[] memory data = abi.decode(payload, (bytes[]));

        bool success;
        bytes memory returnData;
        for (uint256 i; i < data.length; i++) {
            // TODO: bubble up the return
            (success, returnData) = address(this).call(data[i]);
            if (!success) revert("EXECUTE_FAILED");
        }
        // zeroOut();

        return returnData;
    }

    // NOTE: more gas efficient as LiquidityAmounts is used offchain
    // TODO: deadline check
    function mint(
        LiquidityRange calldata range,
        uint256 liquidity,
        uint256 deadline,
        address recipient,
        bytes calldata hookData
    ) public payable returns (uint256 tokenId, BalanceDelta delta) {
        // TODO: optimization, read/write manager.isUnlocked to avoid repeated external calls for batched execution
        if (manager.isUnlocked()) {
            _increaseLiquidity(recipient, range, liquidity, hookData);

            // TODO: should be triggered by zeroOut in _execute...
            delta = recipient.getBalanceDelta(range.poolKey.currency0, range.poolKey.currency1);
            BalanceDelta thisDelta = address(this).getBalanceDelta(range.poolKey.currency0, range.poolKey.currency1);

            _closeCallerDeltas(delta, range.poolKey.currency0, range.poolKey.currency1, recipient, false);
            _closeThisDeltas(thisDelta, range.poolKey.currency0, range.poolKey.currency1);

            // mint receipt token
            _mint(recipient, (tokenId = _nextId++));
            tokenPositions[tokenId] = TokenPosition({owner: recipient, range: range});
        } else {
            bytes[] memory data = new bytes[](1);
            data[0] = abi.encodeWithSelector(this.mint.selector, range, liquidity, deadline, recipient, hookData);
            bytes memory result = unlockAndExecute(data);
            (tokenId, delta) = abi.decode(result, (uint256, BalanceDelta));
        }
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

        if (manager.isUnlocked()) {
            BalanceDelta thisDelta;
            (delta, thisDelta) = _increaseLiquidity(tokenPos.owner, tokenPos.range, liquidity, hookData);

            // TODO: should be triggered by zeroOut in _execute...
            _closeCallerDeltas(
                delta, tokenPos.range.poolKey.currency0, tokenPos.range.poolKey.currency1, tokenPos.owner, claims
            );
            _closeThisDeltas(thisDelta, tokenPos.range.poolKey.currency0, tokenPos.range.poolKey.currency1);
        } else {
            bytes[] memory data = new bytes[](1);
            data[0] = abi.encodeWithSelector(this.increaseLiquidity.selector, tokenId, liquidity, hookData, claims);
            bytes memory result = unlockAndExecute(data);
            delta = abi.decode(result, (BalanceDelta));
        }
    }

    function decreaseLiquidity(uint256 tokenId, uint256 liquidity, bytes calldata hookData, bool claims)
        public
        isAuthorizedForToken(tokenId)
        returns (BalanceDelta delta, BalanceDelta thisDelta)
    {
        TokenPosition memory tokenPos = tokenPositions[tokenId];

        if (manager.isUnlocked()) {
            (delta, thisDelta) = _decreaseLiquidity(tokenPos.owner, tokenPos.range, liquidity, hookData);
            _closeCallerDeltas(
                delta, tokenPos.range.poolKey.currency0, tokenPos.range.poolKey.currency1, tokenPos.owner, claims
            );
            _closeThisDeltas(thisDelta, tokenPos.range.poolKey.currency0, tokenPos.range.poolKey.currency1);
        } else {
            bytes[] memory data = new bytes[](1);
            data[0] = abi.encodeWithSelector(this.decreaseLiquidity.selector, tokenId, liquidity, hookData, claims);
            bytes memory result = unlockAndExecute(data);
            (delta, thisDelta) = abi.decode(result, (BalanceDelta, BalanceDelta));
        }
    }

    function burn(uint256 tokenId, address recipient, bytes calldata hookData, bool claims)
        external
        isAuthorizedForToken(tokenId)
        returns (BalanceDelta delta)
    {
        // TODO: Burn currently decreases and collects. However its done under different locks.
        // Replace once we have the execute multicall.
        // remove liquidity
        TokenPosition storage tokenPosition = tokenPositions[tokenId];
        LiquidityRangeId rangeId = tokenPosition.range.toId();
        Position storage position = positions[msg.sender][rangeId];
        if (position.liquidity > 0) {
            (delta,) = decreaseLiquidity(tokenId, position.liquidity, hookData, claims);
        }

        collect(tokenId, recipient, hookData, claims);
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
        if (manager.isUnlocked()) {
            BalanceDelta thisDelta;
            (delta, thisDelta) = _collect(tokenPos.owner, tokenPos.range, hookData);
            _closeCallerDeltas(
                delta, tokenPos.range.poolKey.currency0, tokenPos.range.poolKey.currency1, tokenPos.owner, claims
            );
            _closeThisDeltas(thisDelta, tokenPos.range.poolKey.currency0, tokenPos.range.poolKey.currency1);
        } else {
            bytes[] memory data = new bytes[](1);
            data[0] = abi.encodeWithSelector(this.collect.selector, tokenId, recipient, hookData, claims);
            bytes memory result = unlockAndExecute(data);
            delta = abi.decode(result, (BalanceDelta));
        }
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
        require(msg.sender == address(this) || _isApprovedOrOwner(msg.sender, tokenId), "Not approved");
        _;
    }
}
