// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./base/PeripheryImmutableState.sol";
import "./base/PeripheryValidation.sol";
import "./interfaces/INonfungiblePositionManager.sol";
import {TickMath} from "@uniswap/v4-core/contracts/libraries/TickMath.sol";
import {Pool} from "@uniswap/v4-core/contracts/libraries/Pool.sol";
import {Position} from "@uniswap/v4-core/contracts/libraries/Position.sol";
import {BalanceDelta} from "@uniswap/v4-core/contracts/types/BalanceDelta.sol";
import {LiquidityAmounts} from "./libraries/LiquidityAmounts.sol";
import {IPoolManager, PoolManager} from "@uniswap/v4-core/contracts/PoolManager.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/contracts/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/contracts/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/contracts/types/PoolKey.sol";
import "forge-std/console.sol";

contract NonfungiblePositionManager is
    ERC721,
    PeripheryImmutableState,
    INonfungiblePositionManager,
    PeripheryValidation
{
    using PoolIdLibrary for PoolKey;

    /// @dev The ID of the next token that will be minted. Skips 0
    uint256 private _nextId = 1;

    struct CallbackData {
        address sender;
        MintParams params;
    }

    // details about the uniswap position
    struct TokenIdPosition {
        PoolKey poolKey;
        // the tick range of the position
        int24 tickLower;
        int24 tickUpper;
        // the liquidity of the position
        uint128 liquidity;
        // the fee growth of the aggregate position as of the last action on the individual position
        uint256 feeGrowthInside0LastX128;
        uint256 feeGrowthInside1LastX128;
        // how many uncollected tokens are owed to the position, as of the last computation
        uint128 tokensOwed0;
        uint128 tokensOwed1;
    }

    /// @dev The token ID position data
    mapping(uint256 => TokenIdPosition) public positions;

    constructor(PoolManager _poolManager, address _WETH9)
        ERC721("Uniswap V4 Positions NFT-V1", "UNI-V4-POS")
        PeripheryImmutableState(_poolManager, _WETH9)
    {}

    function mint(MintParams calldata params)
        external
        payable
        override
        checkDeadline(params.deadline)
        returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1)
    {
        (tokenId, liquidity, amount0, amount1) = abi.decode(
            poolManager.lock(abi.encode(CallbackData(msg.sender, params))), (uint256, uint128, uint256, uint256)
        );
        emit IncreaseLiquidity(tokenId, liquidity, amount0, amount1);
    }

    function lockAcquired(bytes calldata rawData) external returns (bytes memory) {
        require(msg.sender == address(poolManager));
        CallbackData memory data = abi.decode(rawData, (CallbackData));
        MintParams memory params = data.params;
        PoolId poolId = params.poolKey.toId();
        (uint160 sqrtPriceX96,,,,,) = poolManager.getSlot0(poolId);
        uint160 sqrtRatioAX96 = TickMath.getSqrtRatioAtTick(params.tickLower);
        uint160 sqrtRatioBX96 = TickMath.getSqrtRatioAtTick(params.tickUpper);
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96, sqrtRatioAX96, sqrtRatioBX96, params.amount0Desired, params.amount1Desired
        );
        BalanceDelta delta = poolManager.modifyPosition(
            params.poolKey,
            IPoolManager.ModifyPositionParams(params.tickLower, params.tickUpper, int256(int128(liquidity)))
        );

        uint256 tokenId = _nextId++;
        _mint(params.recipient, tokenId);

        Position.Info memory positionInfo =
            poolManager.getPosition(poolId, address(this), params.tickLower, params.tickUpper);
        positions[tokenId] = TokenIdPosition({
            poolKey: params.poolKey,
            tickLower: params.tickLower,
            tickUpper: params.tickUpper,
            liquidity: liquidity,
            feeGrowthInside0LastX128: positionInfo.feeGrowthInside0LastX128,
            feeGrowthInside1LastX128: positionInfo.feeGrowthInside1LastX128,
            tokensOwed0: 0,
            tokensOwed1: 0
        });

        console.log("delta.amount0()");
        console.logInt(delta.amount0());
        if (delta.amount0() > 0) {
            IERC20(Currency.unwrap(params.poolKey.currency0)).transferFrom(
                data.sender, address(poolManager), uint256(int256(delta.amount0()))
            );
            poolManager.settle(params.poolKey.currency0);
        } else if (delta.amount0() < 0) {
            poolManager.take(params.poolKey.currency0, address(this), uint128(-delta.amount0()));
        }
        console.log("delta.amount1()");
        console.logInt(delta.amount1());
        if (delta.amount1() > 0) {
            IERC20(Currency.unwrap(params.poolKey.currency1)).transferFrom(
                data.sender, address(poolManager), uint256(int256(delta.amount1()))
            );
            poolManager.settle(params.poolKey.currency1);
        } else if (delta.amount1() < 0) {
            poolManager.take(params.poolKey.currency1, address(this), uint128(-delta.amount1()));
        }
        return abi.encode(tokenId, liquidity, delta.amount0(), delta.amount1());
    }
}
