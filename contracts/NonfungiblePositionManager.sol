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

    // TODO: TSTORE these jawns
    address internal msgSender;
    bool internal unlockedByThis;

    // TODO: Context is inherited through ERC721 and will be not useful to use _msgSender() which will be address(this) with our current mutlicall.
    function _msgSenderInternal() internal override returns (address) {
        return msgSender;
    }

    constructor(IPoolManager _manager)
        BaseLiquidityManagement(_manager)
        ERC721Permit("Uniswap V4 Positions NFT-V1", "UNI-V4-POS", "1")
    {}

    function unlockAndExecute(bytes[] memory data, Currency[] memory currencies) public returns (int128[] memory) {
        msgSender = msg.sender;
        unlockedByThis = true;
        return abi.decode(manager.unlock(abi.encode(data, currencies)), (int128[]));
    }

    function _unlockCallback(bytes calldata payload) internal override returns (bytes memory) {
        (bytes[] memory data, Currency[] memory currencies) = abi.decode(payload, (bytes[], Currency[]));

        bool success;

        for (uint256 i; i < data.length; i++) {
            // TODO: bubble up the return
            (success,) = address(this).call(data[i]);
            if (!success) revert("EXECUTE_FAILED");
        }

        // close the deltas
        int128[] memory returnData = new int128[](currencies.length);
        for (uint256 i; i < currencies.length; i++) {
            returnData[i] = currencies[i].close(manager, msgSender, false); // TODO: support claims
            currencies[i].close(manager, address(this), true); // position manager always takes 6909
        }

        // Should just be returning the netted amount that was settled on behalf of the caller (msgSender)
        // TODO: any recipient deltas settled earlier.
        // @comment sauce: i dont think we can return recipient deltas since we cant parse the payload
        return abi.encode(returnData);
    }

    // NOTE: more gas efficient as LiquidityAmounts is used offchain
    // TODO: deadline check
    function mint(
        LiquidityRange calldata range,
        uint256 liquidity,
        uint256 deadline,
        address owner,
        bytes calldata hookData
    ) external payable onlyIfUnlocked {
        _increaseLiquidity(owner, range, liquidity, hookData);

        // mint receipt token
        uint256 tokenId;
        _mint(owner, (tokenId = nextTokenId++));
        tokenPositions[tokenId] = TokenPosition({owner: owner, range: range, operator: address(0x0)});
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
        onlyIfUnlocked
    {
        TokenPosition memory tokenPos = tokenPositions[tokenId];

        _increaseLiquidity(tokenPos.owner, tokenPos.range, liquidity, hookData);
    }

    function decreaseLiquidity(uint256 tokenId, uint256 liquidity, bytes calldata hookData, bool claims)
        external
        isAuthorizedForToken(tokenId)
        onlyIfUnlocked
    {
        TokenPosition memory tokenPos = tokenPositions[tokenId];

        _decreaseLiquidity(tokenPos.owner, tokenPos.range, liquidity, hookData);
    }

    // TODO return type?
    function burn(uint256 tokenId) public isAuthorizedForToken(tokenId) returns (BalanceDelta delta) {
        // TODO: Burn currently requires a decrease and collect call before the token can be deleted. Possible to combine.
        // We do not need to enforce the pool manager to be unlocked bc this function is purely clearing storage for the minted tokenId.
        TokenPosition memory tokenPos = tokenPositions[tokenId];
        // Checks that the full position's liquidity has been removed and all tokens have been collected from tokensOwed.
        _validateBurn(tokenPos.owner, tokenPos.range);
        delete tokenPositions[tokenId];
        // Burn the token.
        _burn(tokenId);
    }

    // TODO: in v3, we can partially collect fees, but what was the usecase here?
    function collect(uint256 tokenId, address recipient, bytes calldata hookData, bool claims)
        external
        onlyIfUnlocked
    {
        TokenPosition memory tokenPos = tokenPositions[tokenId];

        _collect(recipient, tokenPos.owner, tokenPos.range, hookData);
    }

    function feesOwed(uint256 tokenId) external view returns (uint256 token0Owed, uint256 token1Owed) {
        TokenPosition memory tokenPosition = tokenPositions[tokenId];
        return feesOwed(tokenPosition.owner, tokenPosition.range);
    }

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

    modifier isAuthorizedForToken(uint256 tokenId) {
        require(msg.sender == address(this) || _isApprovedOrOwner(msg.sender, tokenId), "Not approved");
        _;
    }

    modifier onlyIfUnlocked() {
        if (!unlockedByThis) revert MustBeUnlockedByThisContract();
        _;
    }
}
