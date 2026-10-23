// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IUniswapV2Factory} from "briefcase/protocols/v2-core/interfaces/IUniswapV2Factory.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IUniswapV2Pair} from "briefcase/protocols/v2-core/interfaces/IUniswapV2Pair.sol";
import {BaseLiquidityAdapterHook} from "../base/hooks/BaseLiquidityAdapterHook.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {UniswapV2Library} from "../libraries/UniswapV2Library.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";

/// @title UniswapV2AdapterHook
/// @author Uniswap V4 Hooks
/// @notice Adapter hook that routes V4 swaps through Uniswap V2 liquidity pools
/// @dev Enables V4 pools to leverage existing V2 liquidity without migration
contract UniswapV2AdapterHook is BaseLiquidityAdapterHook {
    error InvalidFee();
    error InvalidTickSpacing();

    uint32 constant POOL_FEE = 3000;
    int24 constant POOL_TICK_SPACING = 1;

    /// @notice The Uniswap V2 factory contract for accessing V2 pairs
    IUniswapV2Factory public immutable v2Factory;
    bytes32 constant UNISWAP_V2_INIT_CODE_HASH = hex"96e8ac4277198ff8b6f785478aa9a39f403cb768dd02cbee326c3e7da348845f";

    /// @notice Initializes the Uniswap V2 adapter hook
    /// @param _manager The Uniswap V4 pool manager contract
    /// @param _v2Factory The Uniswap V2 factory contract address
    constructor(IPoolManager _manager, IUniswapV2Factory _v2Factory) BaseLiquidityAdapterHook(_manager) {
        v2Factory = _v2Factory;
    }

    /// @inheritdoc BaseLiquidityAdapterHook
    /// @dev Routes exact input swaps through the corresponding V2 pair
    function _swapExactInput(PoolKey calldata poolKey, SwapParams calldata params)
        internal
        override
        returns (uint256 amountOut)
    {
        (
            Currency tokenIn,
            Currency tokenOut,
            address pair,
            uint256 reserveIn,
            uint256 reserveOut,
            uint256 amountSpecified
        ) = _parseSwap(poolKey, params);
        amountOut = UniswapV2Library.getAmountOut(amountSpecified, reserveIn, reserveOut);
        (uint256 amount0Out, uint256 amount1Out) = params.zeroForOne ? (uint256(0), amountOut) : (amountOut, uint256(0));

        // Sync output token balance before V2 swap
        poolManager.sync(tokenOut);
        // Transfer input tokens from V4 pool manager directly to V2 pair
        _take(tokenIn, pair, amountSpecified);
        IUniswapV2Pair(pair).swap(amount0Out, amount1Out, address(poolManager), new bytes(0));
        // Settle with V4 pool manager to account for output tokens received
        poolManager.settle();
    }

    /// @inheritdoc BaseLiquidityAdapterHook
    /// @dev Routes exact output swaps through the corresponding V2 pair
    function _swapExactOutput(PoolKey calldata poolKey, SwapParams calldata params)
        internal
        override
        returns (uint256 amountIn)
    {
        (
            Currency tokenIn,
            Currency tokenOut,
            address pair,
            uint256 reserveIn,
            uint256 reserveOut,
            uint256 amountSpecified
        ) = _parseSwap(poolKey, params);
        amountIn = UniswapV2Library.getAmountIn(amountSpecified, reserveIn, reserveOut);
        (uint256 amount0Out, uint256 amount1Out) =
            params.zeroForOne ? (uint256(0), amountSpecified) : (amountSpecified, uint256(0));

        // Sync output token balance before V2 swap
        poolManager.sync(tokenOut);
        // Transfer input tokens from V4 pool manager directly to V2 pair
        _take(tokenIn, pair, amountIn);
        IUniswapV2Pair(pair).swap(amount0Out, amount1Out, address(poolManager), new bytes(0));
        // Settle with V4 pool manager to account for output tokens received
        poolManager.settle();
    }

    /// @inheritdoc BaseLiquidityAdapterHook
    /// @dev Checks if a V2 pair exists for the given token pair
    function _liquidityExists(PoolKey calldata poolKey) internal view override returns (bool exists) {
        if (poolKey.fee != POOL_FEE) revert InvalidFee();
        if (poolKey.tickSpacing != POOL_TICK_SPACING) revert InvalidTickSpacing();
        return v2Factory.getPair(Currency.unwrap(poolKey.currency0), Currency.unwrap(poolKey.currency1)) != address(0);
    }

    /// @notice Parses swap parameters to determine tokens and amounts
    /// @dev Extracts token direction, V2 pair address, and swap amount from V4 parameters
    /// @param poolKey The V4 pool configuration
    /// @param params The V4 swap parameters
    /// @return tokenIn The input token currency
    /// @return tokenOut The output token currency
    /// @return pair The V2 pair contract for this token pair
    /// @return reserveIn The reserve of the input token on the pair
    /// @return reserveOut The reserve of the output token on the pair
    /// @return amountSpecified The absolute swap amount
    function _parseSwap(PoolKey calldata poolKey, SwapParams calldata params)
        private
        view
        returns (
            Currency tokenIn,
            Currency tokenOut,
            address pair,
            uint256 reserveIn,
            uint256 reserveOut,
            uint256 amountSpecified
        )
    {
        (tokenIn, tokenOut) =
            params.zeroForOne ? (poolKey.currency0, poolKey.currency1) : (poolKey.currency1, poolKey.currency0);
        (pair, reserveIn, reserveOut) = UniswapV2Library.pairAndReservesFor(
            address(v2Factory), UNISWAP_V2_INIT_CODE_HASH, Currency.unwrap(tokenIn), Currency.unwrap(tokenOut)
        );
        amountSpecified =
            params.amountSpecified > 0 ? uint256(params.amountSpecified) : uint256(-params.amountSpecified);
    }
}
