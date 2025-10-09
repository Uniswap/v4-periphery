// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BaseLiquidityAdapterHook} from "../base/hooks/BaseLiquidityAdapterHook.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";

/// @title CurveAdapterHook
/// @author Uniswap V4 Hooks
/// @notice Adapter hook that routes V4 swaps through Curve liquidity pools
/// @dev Enables V4 pools to leverage existing Curve liquidity without migration
/// @notice Interface for Curve pool operations
interface ICurvePool {
    function get_dy(int128 i, int128 j, uint256 dx) external view returns (uint256);
    function exchange(int128 i, int128 j, uint256 dx, uint256 min_dy) external returns (uint256);
    function coins(uint256 i) external view returns (address);
}

/// @notice Interface for Curve oracle to get aggregated rates
interface ICurveOracle {
    function get_aggregated_rate(address token_in, address token_out) external view returns (uint256);
}

contract CurveAdapterHook is BaseLiquidityAdapterHook {
    error InvalidFee();
    error InvalidTickSpacing();
    error CurvePoolNotFound();
    error InvalidTokenIndex();

    uint32 constant POOL_FEE = 3000;
    int24 constant POOL_TICK_SPACING = 1;

    /// @notice The Curve oracle contract for getting exchange rates
    ICurveOracle public immutable curveOracle;

    /// @notice The Curve 2pool contract address
    address public immutable curve2Pool;

    /// @notice Mapping from V4 pool key hash to token indices in Curve 2pool
    mapping(bytes32 => int128[2]) public poolTokenIndices;

    /// @notice Initializes the Curve adapter hook
    /// @param _manager The Uniswap V4 pool manager contract
    /// @param _curveOracle The Curve oracle contract address
    /// @param _curve2Pool The Curve 2pool contract address
    constructor(IPoolManager _manager, ICurveOracle _curveOracle, address _curve2Pool) BaseLiquidityAdapterHook(_manager) {
        curveOracle = _curveOracle;
        curve2Pool = _curve2Pool;
    }

    /// @notice Sets the token indices for a V4 pool key in the Curve 2pool
    /// @param poolKey The V4 pool configuration
    /// @param token0Index The index of currency0 in the Curve 2pool
    /// @param token1Index The index of currency1 in the Curve 2pool
    function setTokenIndices(
        PoolKey calldata poolKey,
        int128 token0Index,
        int128 token1Index
    ) external {
        bytes32 keyHash = keccak256(abi.encode(poolKey));
        poolTokenIndices[keyHash] = [token0Index, token1Index];
    }

    /// @notice Gets the token indices for a given token pair in the Curve 2pool
    /// @dev Assumes the tokens are in the 2pool and returns their indices
    /// @param tokenA First token address
    /// @param tokenB Second token address
    /// @return tokenAIndex The index of tokenA in the Curve 2pool
    /// @return tokenBIndex The index of tokenB in the Curve 2pool
    function getTokenIndices(address tokenA, address tokenB)
        public
        view
        returns (int128 tokenAIndex, int128 tokenBIndex)
    {
        // Check which token is at index 0 and 1 in the 2pool
        address token0 = ICurvePool(curve2Pool).coins(0);
        address token1 = ICurvePool(curve2Pool).coins(1);

        if (tokenA == token0 && tokenB == token1) {
            return (0, 1);
        } else if (tokenA == token1 && tokenB == token0) {
            return (1, 0);
        } else {
            revert InvalidTokenIndex();
        }
    }

    /// @inheritdoc BaseLiquidityAdapterHook
    /// @dev Routes exact input swaps through the corresponding Curve pool
    function _swapExactInput(PoolKey calldata poolKey, SwapParams calldata params)
        internal
        override
        returns (uint256 amountOut)
    {
        (
            Currency tokenIn,
            Currency tokenOut,
            int128 tokenInIndex,
            int128 tokenOutIndex,
            uint256 amountSpecified
        ) = _parseSwap(poolKey, params);

        // Get amountOut using Curve's get_dy function
        amountOut = ICurvePool(curve2Pool).get_dy(tokenInIndex, tokenOutIndex, amountSpecified);

        // Sync output token balance before Curve swap
        poolManager.sync(tokenOut);

        // Transfer input tokens from V4 pool manager directly to Curve 2pool
        _take(tokenIn, curve2Pool, amountSpecified);

        // Execute the swap on Curve 2pool
        ICurvePool(curve2Pool).exchange(tokenInIndex, tokenOutIndex, amountSpecified, 0);

        // Settle with V4 pool manager to account for output tokens received
        poolManager.settle();
    }

    /// @inheritdoc BaseLiquidityAdapterHook
    /// @dev Routes exact output swaps through the corresponding Curve pool
    function _swapExactOutput(PoolKey calldata poolKey, SwapParams calldata params)
        internal
        override
        returns (uint256 amountIn)
    {
        (
            Currency tokenIn,
            Currency tokenOut,
            int128 tokenInIndex,
            int128 tokenOutIndex,
            uint256 amountSpecified
        ) = _parseSwap(poolKey, params);

        // For exact output, we need to estimate the input amount
        // We can use the oracle rate to get an approximation
        uint256 rate = curveOracle.get_aggregated_rate(Currency.unwrap(tokenIn), Currency.unwrap(tokenOut));
        amountIn = (amountSpecified * 1e18) / rate;

        // Sync output token balance before Curve swap
        poolManager.sync(tokenOut);

        // Transfer input tokens from V4 pool manager directly to Curve 2pool
        _take(tokenIn, curve2Pool, amountIn);

        // Execute the swap on Curve 2pool
        ICurvePool(curve2Pool).exchange(tokenInIndex, tokenOutIndex, amountIn, amountSpecified);

        // Settle with V4 pool manager to account for output tokens received
        poolManager.settle();
    }

    /// @inheritdoc BaseLiquidityAdapterHook
    /// @dev Checks if the token pair exists in the Curve 2pool
    function _liquidityExists(PoolKey calldata poolKey) internal view override returns (bool exists) {
        if (poolKey.fee != POOL_FEE) revert InvalidFee();
        if (poolKey.tickSpacing != POOL_TICK_SPACING) revert InvalidTickSpacing();

        // Check if both tokens are in the Curve 2pool
        try this.getTokenIndices(Currency.unwrap(poolKey.currency0), Currency.unwrap(poolKey.currency1)) returns (int128, int128) {
            return true;
        } catch {
            return false;
        }
    }

    /// @notice Parses swap parameters to determine tokens and amounts
    /// @dev Extracts token direction and swap amount from V4 parameters for Curve 2pool
    /// @param poolKey The V4 pool configuration
    /// @param params The V4 swap parameters
    /// @return tokenIn The input token currency
    /// @return tokenOut The output token currency
    /// @return tokenInIndex The index of input token in Curve 2pool
    /// @return tokenOutIndex The index of output token in Curve 2pool
    /// @return amountSpecified The absolute swap amount
    function _parseSwap(PoolKey calldata poolKey, SwapParams calldata params)
        private
        view
        returns (
            Currency tokenIn,
            Currency tokenOut,
            int128 tokenInIndex,
            int128 tokenOutIndex,
            uint256 amountSpecified
        )
    {
        (tokenIn, tokenOut) =
            params.zeroForOne ? (poolKey.currency0, poolKey.currency1) : (poolKey.currency1, poolKey.currency0);

        bytes32 keyHash = keccak256(abi.encode(poolKey));
        int128[2] memory indices = poolTokenIndices[keyHash];

        if (indices[0] != 0 || indices[1] != 0) {
            // Use manual mapping if available
            (tokenInIndex, tokenOutIndex) = params.zeroForOne ? (indices[0], indices[1]) : (indices[1], indices[0]);
        } else {
            // Fall back to automatic discovery
            (tokenInIndex, tokenOutIndex) = getTokenIndices(
                Currency.unwrap(tokenIn), 
                Currency.unwrap(tokenOut)
            );
        }

        amountSpecified =
            params.amountSpecified > 0 ? uint256(params.amountSpecified) : uint256(-params.amountSpecified);
    }

    /// @notice Gets the amount out for a given amount in using Curve oracle rate
    /// @dev Alternative method using oracle rates instead of get_dy
    /// @param tokenIn The input token address
    /// @param tokenOut The output token address
    /// @param amountIn The input amount
    /// @return amountOut The estimated output amount
    function getAmountOutFromOracle(address tokenIn, address tokenOut, uint256 amountIn)
        external
        view
        returns (uint256 amountOut)
    {
        uint256 rate = curveOracle.get_aggregated_rate(tokenIn, tokenOut);
        amountOut = (amountIn * rate) / 1e18;
    }
}
