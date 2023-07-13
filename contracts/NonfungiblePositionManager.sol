// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "./base/PeripheryImmutableState.sol";
import "./base/PeripheryValidation.sol";
import "./interfaces/INonfungiblePositionManager.sol";
import {TickMath} from "@uniswap/v4-core/contracts/libraries/TickMath.sol";
import {Pool} from "@uniswap/v4-core/contracts/libraries/Pool.sol";
import {BalanceDelta} from "@uniswap/v4-core/contracts/types/BalanceDelta.sol";
import {LiquidityAmounts} from "./libraries/LiquidityAmounts.sol";
import {IPoolManager, PoolManager} from "@uniswap/v4-core/contracts/PoolManager.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/contracts/libraries/PoolId.sol";

contract NonfungiblePositionManager is
    ERC721,
    PeripheryImmutableState,
    INonfungiblePositionManager,
    PeripheryValidation
{
    using PoolIdLibrary for IPoolManager.PoolKey;

    struct CallbackData {
        address sender;
        MintParams params;
    }

    constructor(PoolManager _poolManager, address _WETH9)
        ERC721("Uniswap V4 Positions NFT-V1", "UNI-V4-POS")
        PeripheryImmutableState(_poolManager, _WETH9)
    {}

    function mint(MintParams calldata params)
        external
        payable
        override
        checkDeadline(params.deadline)
        returns (BalanceDelta delta)
    {
        delta = abi.decode(poolManager.lock(abi.encode(CallbackData(msg.sender, params))), (BalanceDelta));
    }

    function lockAcquired(uint256, bytes calldata rawData) external returns (bytes memory) {
        require(msg.sender == address(poolManager));
        CallbackData memory data = abi.decode(rawData, (CallbackData));
        PoolId poolId = data.params.poolKey.toId();
        (uint160 sqrtPriceX96,,,,,) = poolManager.getSlot0(poolId);
        uint160 sqrtRatioAX96 = TickMath.getSqrtRatioAtTick(data.params.tickLower);
        uint160 sqrtRatioBX96 = TickMath.getSqrtRatioAtTick(data.params.tickUpper);
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96, sqrtRatioAX96, sqrtRatioBX96, data.params.amount0Desired, data.params.amount1Desired
        );
        BalanceDelta delta = poolManager.modifyPosition(
            data.params.poolKey,
            IPoolManager.ModifyPositionParams(data.params.tickLower, data.params.tickUpper, int256(int128(liquidity)))
        );
        return abi.encode(delta);
    }
}
