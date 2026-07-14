// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {
    toBeforeSwapDelta, BeforeSwapDelta, BeforeSwapDeltaLibrary
} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {BaseHook} from "../../utils/BaseHook.sol";
import {DeltaResolver} from "../DeltaResolver.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

/// @title BaseLiquidityAdapterHook
/// @author Uniswap V4 Hooks
/// @notice Abstract base contract for adapting external liquidity sources to Uniswap V4 pools
/// @dev Provides core functionality for integrating alternative AMMs and liquidity protocols with V4
/// @dev Liquidity operations (add/remove) are disabled - all liquidity is managed externally
/// @dev Inheritors must implement: _swapExactInput, _swapExactOutput, and _liquidityExists
abstract contract BaseLiquidityAdapterHook is BaseHook, DeltaResolver {
    using CurrencyLibrary for Currency;
    using SafeCast for int256;
    using SafeCast for uint256;

    /// @notice Thrown when attempting to add or remove liquidity
    /// @dev Liquidity operations are disabled as liquidity is managed by the external source
    error LiquidityNotAllowed();

    /// @notice Thrown when initializing a pool that doesn't have corresponding external liquidity
    /// @dev The external liquidity source must support the given token pair
    error InvalidPool();

    /// @notice Initializes the base liquidity adapter hook
    /// @param _manager The Uniswap V4 pool manager contract
    constructor(IPoolManager _manager) BaseHook(_manager) {}

    /// @inheritdoc BaseHook
    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            beforeSwap: true,
            beforeSwapReturnDelta: true,
            beforeAddLiquidity: true,
            afterSwap: false,
            afterInitialize: false,
            beforeRemoveLiquidity: false,
            afterAddLiquidity: false,
            afterRemoveLiquidity: false,
            beforeDonate: false,
            afterDonate: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    /// @notice Hook called before pool initialization to validate compatibility
    /// @dev Ensures the external liquidity source supports the given token pair
    /// @param poolKey The pool configuration containing token pair and fee settings
    /// @return bytes4 The beforeInitialize selector on success
    function _beforeInitialize(address, PoolKey calldata poolKey, uint160) internal view override returns (bytes4) {
        // ensure the pool is supported by the underlying liquidity source
        if (!_liquidityExists(poolKey)) revert InvalidPool();

        return IHooks.beforeInitialize.selector;
    }

    /// @notice Hook called before adding liquidity - always reverts
    /// @dev Liquidity provision is disabled as all liquidity comes from external source
    function _beforeAddLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        internal
        pure
        override
        returns (bytes4)
    {
        revert LiquidityNotAllowed();
    }

    /// @notice Hook called before swap execution to route through external liquidity
    /// @dev Handles both exact input (amountSpecified < 0) and exact output (amountSpecified > 0)
    /// @param poolKey The pool configuration
    /// @param params Swap parameters including direction, amount, and sqrtPriceLimit
    /// @return bytes4 The beforeSwap selector
    /// @return swapDelta The token deltas for pool accounting
    /// @return uint24 LP fee override (always 0 as fees are handled externally)
    function _beforeSwap(address, PoolKey calldata poolKey, SwapParams calldata params, bytes calldata)
        internal
        override
        returns (bytes4, BeforeSwapDelta swapDelta, uint24)
    {
        bool isExactInput = params.amountSpecified < 0;

        if (isExactInput) {
            uint256 amountOut = _swapExactInput(poolKey, params);
            swapDelta = toBeforeSwapDelta(-params.amountSpecified.toInt128(), -int128(int256(amountOut)));
        } else {
            uint256 amountIn = _swapExactOutput(poolKey, params);
            swapDelta = toBeforeSwapDelta(-params.amountSpecified.toInt128(), int128(int256(amountIn)));
        }

        return (IHooks.beforeSwap.selector, swapDelta, 0);
    }

    /// @inheritdoc DeltaResolver
    /// @notice Settles positive deltas by transferring tokens to the pool manager
    /// @param token The currency to transfer
    /// @param amount The amount to transfer to the pool manager
    function _pay(Currency token, address, uint256 amount) internal override {
        token.transfer(address(poolManager), amount);
    }

    /// @notice Executes a swap with exact input amount through external liquidity
    /// @param poolKey The pool configuration
    /// @param params Swap parameters with negative amountSpecified
    /// @return amountOut The amount of output tokens received
    function _swapExactInput(PoolKey calldata poolKey, SwapParams calldata params)
        internal
        virtual
        returns (uint256 amountOut);

    /// @notice Executes a swap with exact output amount through external liquidity
    /// @param poolKey The pool configuration
    /// @param params Swap parameters with positive amountSpecified
    /// @return amountIn The amount of input tokens required
    function _swapExactOutput(PoolKey calldata poolKey, SwapParams calldata params)
        internal
        virtual
        returns (uint256 amountIn);

    /// @notice Checks if the external liquidity source supports the given pool
    /// @param poolKey The pool configuration to validate
    /// @return exists True if external liquidity exists for this token pair
    function _liquidityExists(PoolKey calldata poolKey) internal view virtual returns (bool exists);
}
