// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {LiquidityRange} from "../types/LiquidityRange.sol";
import {IBaseLiquidityManagement} from "./IBaseLiquidityManagement.sol";

interface INonfungiblePositionManager is IBaseLiquidityManagement {
    struct MintParams {
        LiquidityRange range;
        uint256 amount0Desired;
        uint256 amount1Desired;
        uint256 amount0Min;
        uint256 amount1Min;
        uint256 deadline;
        address recipient;
        bytes hookData;
    }

    // NOTE: more gas efficient as LiquidityAmounts is used offchain
    function mint(
        LiquidityRange calldata position,
        uint256 liquidity,
        uint256 deadline,
        address recipient,
        bytes calldata hookData
    ) external payable returns (uint256 tokenId, BalanceDelta delta);

    // NOTE: more expensive since LiquidityAmounts is used onchain
    function mint(MintParams calldata params) external payable returns (uint256 tokenId, BalanceDelta delta);

    struct DecreaseLiquidityParams {
        uint256 tokenId;
        uint128 liquidityDelta;
        uint256 amount0Min;
        uint256 amount1Min;
        uint256 deadline;
    }

    function decreaseLiquidity(DecreaseLiquidityParams memory params, bytes calldata hookData)
        external
        returns (BalanceDelta delta);

    function burn(uint256 tokenId, bytes calldata hookData) external returns (BalanceDelta delta);

    // TODO: in v3, we can partially collect fees, but what was the usecase here?
    function collect(uint256 tokenId, address recipient, bytes calldata hookData, bool claims)
        external
        returns (BalanceDelta delta);
}
