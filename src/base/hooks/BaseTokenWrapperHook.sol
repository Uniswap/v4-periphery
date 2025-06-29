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
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {BaseHook} from "../../utils/BaseHook.sol";
import {DeltaResolver} from "../DeltaResolver.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

/// @title Base Token Wrapper Hook
/// @notice Abstract base contract for implementing token wrapper hooks in Uniswap V4
/// @dev This contract provides the base functionality for wrapping/unwrapping tokens through V4 pools
/// @dev All liquidity operations are blocked as liquidity is managed through the underlying token wrapper
/// @dev Implementing contracts must provide deposit() and withdraw() functions
abstract contract BaseTokenWrapperHook is BaseHook, DeltaResolver {
    using CurrencyLibrary for Currency;
    using SafeCast for int256;
    using SafeCast for uint256;
    using CustomRevert for bytes4;

    /// @notice Thrown when attempting to add or remove liquidity
    /// @dev Liquidity operations are blocked since all liquidity is managed by the token wrapper
    error LiquidityNotAllowed();

    /// @notice Thrown when initializing a pool with invalid tokens
    /// @dev Pool must contain exactly one wrapper token and its underlying token
    error InvalidPoolToken();

    /// @notice Thrown when initializing a pool with non-zero fee
    /// @dev Fee must be 0 as wrapper pools don't charge fees
    error InvalidPoolFee();

    /// @notice Thrown when exact input swaps are not supported
    error ExactInputNotSupported();

    /// @notice Thrown when exact output swaps are not supported
    error ExactOutputNotSupported();
    
    /// @notice Thrown when exchange rate calculation would cause overflow
    error ExchangeRateOverflow();
    
    /// @notice Thrown when exchange rate is invalid (zero or extremely small)
    error InvalidExchangeRate();
    
    /// @notice Thrown when swap amount is too large and could cause issues
    error SwapAmountTooLarge();
    
    /// @notice Thrown when hookData exceeds maximum allowed length
    error HookDataTooLarge();
    
    /// @notice Thrown when deposit/withdraw amounts don't match expected bounds
    error AmountMismatch();

    /// @notice Maximum allowed hookData length to prevent DoS attacks
    uint256 public constant MAX_HOOK_DATA_LENGTH = 1024;
    
    /// @notice Maximum swap amount to prevent overflow issues  
    uint256 public constant MAX_SWAP_AMOUNT = type(uint128).max;
    
    /// @notice Minimum exchange rate to prevent division by zero issues
    uint256 public constant MIN_EXCHANGE_RATE = 1e12; // 1e-6 with 18 decimals

    /// @notice The wrapped token currency (e.g., WETH)
    Currency public immutable wrapperCurrency;

    /// @notice The underlying token currency (e.g., ETH)
    Currency public immutable underlyingCurrency;

    /// @notice Indicates whether wrapping occurs when swapping from token0 to token1
    /// @dev This is determined by the relative ordering of the wrapper and underlying tokens
    /// @dev If true: token0 is underlying (e.g. ETH) and token1 is wrapper (e.g. WETH)
    /// @dev If false: token0 is wrapper (e.g. WETH) and token1 is underlying (e.g. ETH)
    /// @dev This is set in the constructor based on the token addresses to ensure consistent behavior
    bool public immutable wrapZeroForOne;

    /// @notice Creates a new token wrapper hook
    /// @param _manager The Uniswap V4 pool manager
    /// @param _wrapper The wrapped token currency (e.g., WETH)
    /// @param _underlying The underlying token currency (e.g., ETH)
    constructor(IPoolManager _manager, Currency _wrapper, Currency _underlying) BaseHook(_manager) {
        wrapperCurrency = _wrapper;
        underlyingCurrency = _underlying;
        wrapZeroForOne = _underlying < _wrapper;
    }

    /// @inheritdoc BaseHook
    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            beforeAddLiquidity: true,
            beforeSwap: true,
            beforeSwapReturnDelta: true,
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

    /// @notice Validates pool initialization parameters
    /// @dev Ensures pool contains wrapper and underlying tokens with zero fee
    /// @param poolKey The pool configuration including tokens and fee
    /// @return The function selector if validation passes
    function _beforeInitialize(address, PoolKey calldata poolKey, uint160) internal view override returns (bytes4) {
        // ensure pool tokens are the wrapper currency and underlying currency
        bool isValidPair = wrapZeroForOne
            ? (poolKey.currency0 == underlyingCurrency && poolKey.currency1 == wrapperCurrency)
            : (poolKey.currency0 == wrapperCurrency && poolKey.currency1 == underlyingCurrency);

        if (!isValidPair) revert InvalidPoolToken();
        if (poolKey.fee != 0) revert InvalidPoolFee();

        return IHooks.beforeInitialize.selector;
    }

    /// @notice Prevents liquidity operations on wrapper pools
    /// @dev Always reverts as liquidity is managed through the token wrapper
    function _beforeAddLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        internal
        pure
        override
        returns (bytes4)
    {
        revert LiquidityNotAllowed();
    }

    /// @notice Handles token wrapping and unwrapping during swaps
    /// @dev Processes both exact input (amountSpecified < 0) and exact output (amountSpecified > 0) swaps
    /// @param params The swap parameters including direction and amount
    /// @param hookData Hook-specific data passed to the swap
    /// @return selector The function selector
    /// @return swapDelta The input/output token amounts for pool accounting
    /// @return lpFeeOverride The fee override (always 0 for wrapper pools)
    function _beforeSwap(address, PoolKey calldata, SwapParams calldata params, bytes calldata hookData)
        internal
        override
        returns (bytes4, BeforeSwapDelta swapDelta, uint24)
    {
        // Critical validation: Limit hookData size to prevent DoS attacks
        if (hookData.length > MAX_HOOK_DATA_LENGTH) {
            HookDataTooLarge.selector.revertWith();
        }
        
        bool isExactInput = params.amountSpecified < 0;
        if (isExactInput && !_supportsExactInput()) ExactInputNotSupported.selector.revertWith();
        if (!isExactInput && !_supportsExactOutput()) ExactOutputNotSupported.selector.revertWith();

        // Critical validation: Prevent overflow in amount calculations
        uint256 swapAmount = isExactInput ? uint256(-params.amountSpecified) : uint256(params.amountSpecified);
        if (swapAmount > MAX_SWAP_AMOUNT) {
            SwapAmountTooLarge.selector.revertWith();
        }
        
        // Validate exchange rates before any calculations to prevent division by zero
        _validateExchangeRates();

        if (wrapZeroForOne == params.zeroForOne) {
            // we are wrapping
            uint256 inputAmount = isExactInput ? swapAmount : _getWrapInputRequired(swapAmount);
            
            // Additional validation for exact output to prevent manipulation
            if (!isExactInput) {
                // Ensure the required input amount is reasonable
                if (inputAmount > MAX_SWAP_AMOUNT || inputAmount == 0) {
                    AmountMismatch.selector.revertWith();
                }
            }
            
            (uint256 actualUnderlyingAmount, uint256 wrappedAmount) = _deposit(inputAmount);
            
            // Critical validation: Ensure deposit amounts are reasonable
            if (actualUnderlyingAmount == 0 || wrappedAmount == 0) {
                AmountMismatch.selector.revertWith();
            }
            
            // Prevent extreme exchange rate deviations that could indicate manipulation
            if (isExactInput) {
                _validateExchangeRateDeviation(inputAmount, wrappedAmount, true);
            } else {
                _validateExchangeRateDeviation(actualUnderlyingAmount, swapAmount, true);
            }
            
            int128 amountUnspecified =
                isExactInput ? -wrappedAmount.toInt256().toInt128() : actualUnderlyingAmount.toInt256().toInt128();
            swapDelta = toBeforeSwapDelta(-params.amountSpecified.toInt128(), amountUnspecified);
        } else {
            // we are unwrapping
            uint256 inputAmount = isExactInput ? swapAmount : _getUnwrapInputRequired(swapAmount);
            
            // Additional validation for exact output to prevent manipulation
            if (!isExactInput) {
                // Ensure the required input amount is reasonable
                if (inputAmount > MAX_SWAP_AMOUNT || inputAmount == 0) {
                    AmountMismatch.selector.revertWith();
                }
            }
            
            (uint256 actualWrappedAmount, uint256 unwrappedAmount) = _withdraw(inputAmount);
            
            // Critical validation: Ensure withdraw amounts are reasonable
            if (actualWrappedAmount == 0 || unwrappedAmount == 0) {
                AmountMismatch.selector.revertWith();
            }
            
            // Prevent extreme exchange rate deviations that could indicate manipulation
            if (isExactInput) {
                _validateExchangeRateDeviation(inputAmount, unwrappedAmount, false);
            } else {
                _validateExchangeRateDeviation(actualWrappedAmount, swapAmount, false);
            }
            
            int128 amountUnspecified =
                isExactInput ? -unwrappedAmount.toInt256().toInt128() : actualWrappedAmount.toInt256().toInt128();
            swapDelta = toBeforeSwapDelta(-params.amountSpecified.toInt128(), amountUnspecified);
        }

        return (IHooks.beforeSwap.selector, swapDelta, 0);
    }

    /// @notice Transfers tokens to the pool manager
    /// @param token The token to transfer
    /// @param amount The amount to transfer
    /// @inheritdoc DeltaResolver
    function _pay(Currency token, address, uint256 amount) internal override {
        token.transfer(address(poolManager), amount);
    }

    /// @notice Deposits underlying tokens to receive wrapper tokens
    /// @param underlyingAmount The amount of underlying tokens to deposit
    /// @return actualUnderlyingAmount the actual number of underlying tokens used, i.e. to account for rebasing rounding errors
    /// @return wrappedAmount The amount of wrapper tokens received
    /// @dev Implementing contracts should handle:
    //    - taking tokens from PoolManager
    //    - performing the wrapping operation
    //    - settling tokens on PoolManager
    function _deposit(uint256 underlyingAmount)
        internal
        virtual
        returns (uint256 actualUnderlyingAmount, uint256 wrappedAmount);

    /// @notice Withdraws wrapper tokens to receive underlying tokens
    /// @param wrappedAmount The amount of wrapper tokens to withdraw
    /// @return actualWrappedAmount the actual number of wrapped tokens used, i.e. to account for rebasing rounding errors
    /// @return underlyingAmount The amount of underlying tokens received
    /// @dev Implementing contracts should handle:
    //    - taking tokens from PoolManager
    //    - performing the unwrapping operation
    //    - settling tokens on PoolManager
    function _withdraw(uint256 wrappedAmount)
        internal
        virtual
        returns (uint256 actualWrappedAmount, uint256 underlyingAmount);

    /// @notice Calculates underlying tokens needed to receive desired wrapper tokens
    /// @param wrappedAmount The desired amount of wrapper tokens
    /// @return The required amount of underlying tokens
    /// @dev Default implementation assumes 1:1 ratio
    /// @dev Override for wrappers with different exchange rates
    function _getWrapInputRequired(uint256 wrappedAmount) internal view virtual returns (uint256) {
        return wrappedAmount;
    }

    /// @notice Calculates wrapper tokens needed to receive desired underlying tokens
    /// @param underlyingAmount The desired amount of underlying tokens
    /// @return The required amount of wrapper tokens
    /// @dev Default implementation assumes 1:1 ratio
    /// @dev Override for wrappers with different exchange rates
    function _getUnwrapInputRequired(uint256 underlyingAmount) internal view virtual returns (uint256) {
        return underlyingAmount;
    }

    /// @notice Indicates whether the hook supports exact output swaps
    /// @dev Default implementation returns true
    /// @dev Override for wrappers that cannot support exact output swaps
    function _supportsExactOutput() internal view virtual returns (bool) {
        return true;
    }

    /// @notice Indicates whether the hook supports exact input swaps
    /// @dev Default implementation returns true
    /// @dev Override for wrappers that cannot support exact input swaps
    function _supportsExactInput() internal view virtual returns (bool) {
        return true;
    }

    /// @notice Validates exchange rates to prevent division by zero and extreme values
    /// @dev Called before any exchange rate calculations to ensure safety
    function _validateExchangeRates() internal view virtual {
        // Default implementation - override in derived contracts for specific validation
        // This should validate that current exchange rates are within reasonable bounds
    }
    
    /// @notice Validates that exchange rate deviations are within acceptable bounds
    /// @param inputAmount The input amount for the operation
    /// @param outputAmount The output amount for the operation  
    /// @param isWrapping True if this is a wrapping operation, false for unwrapping
    /// @dev Prevents extreme exchange rate deviations that could indicate manipulation
    function _validateExchangeRateDeviation(uint256 inputAmount, uint256 outputAmount, bool isWrapping) internal view virtual {
        // Prevent zero amounts which could indicate manipulation or errors
        if (inputAmount == 0 || outputAmount == 0) {
            AmountMismatch.selector.revertWith();
        }
        
        // Calculate the exchange rate with sufficient precision to detect anomalies
        // For wrapping: rate = outputWrapped / inputUnderlyng  
        // For unwrapping: rate = outputUnderlying / inputWrapped
        uint256 rate;
        unchecked {
            if (outputAmount > inputAmount) {
                rate = (outputAmount * 1e18) / inputAmount;
            } else {
                rate = (inputAmount * 1e18) / outputAmount;
            }
        }
        
        // Default validation: ensure rate is above minimum threshold
        // Override in derived contracts for more specific rate validation
        if (rate < MIN_EXCHANGE_RATE) {
            InvalidExchangeRate.selector.revertWith();
        }
        
        // Prevent extreme exchange rates that could indicate overflow or manipulation
        // Maximum reasonable exchange rate variance: 1000x (most volatile tokens)
        if (rate > 1000e18) {
            ExchangeRateOverflow.selector.revertWith();
        }
    }
}
