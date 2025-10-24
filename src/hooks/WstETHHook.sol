// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "solmate/src/tokens/ERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {FixedPointMathLib} from "solmate/src/utils/FixedPointMathLib.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {BaseTokenWrapperHook} from "../base/hooks/BaseTokenWrapperHook.sol";
import {IWstETH, IStETH} from "../interfaces/external/IWstETH.sol";
import {SafeTransferLib} from "solmate/src/utils/SafeTransferLib.sol";

/// @title Wrapped Staked ETH (wstETH) Hook
/// @notice Hook for wrapping/unwrapping stETH/wstETH in Uniswap V4 pools
/// @dev Implements dynamic exchange rate wrapping/unwrapping between stETH and wstETH
/// @dev wstETH represents stETH with accrued staking rewards, maintaining a dynamic exchange rate
contract WstETHHook is BaseTokenWrapperHook {
    using FixedPointMathLib for uint256;
    using SafeTransferLib for ERC20;
    using CustomRevert for bytes4;

    /// @notice The wstETH contract used for wrapping/unwrapping operations
    IWstETH public immutable wstETH;
    
    /// @notice Minimum exchange rate for stETH/wstETH (prevents manipulation)  
    uint256 private constant MIN_WSTETH_RATE = 0.8e18; // 0.8 stETH per wstETH (very conservative)
    
    /// @notice Maximum exchange rate for stETH/wstETH (prevents manipulation)
    uint256 private constant MAX_WSTETH_RATE = 2.0e18; // 2.0 stETH per wstETH (very conservative)

    /// @notice Creates a new wstETH wrapper hook
    /// @param _manager The Uniswap V4 pool manager
    /// @param _wsteth The wstETH contract address
    /// @dev Initializes with wstETH as wrapper token and stETH as underlying token
    constructor(IPoolManager _manager, IWstETH _wsteth)
        BaseTokenWrapperHook(
            _manager,
            Currency.wrap(address(_wsteth)), // wrapper token is wstETH
            Currency.wrap(_wsteth.stETH()) // underlying token is stETH
        )
    {
        wstETH = _wsteth;
        ERC20(Currency.unwrap(underlyingCurrency)).safeApprove(address(wstETH), type(uint256).max);
    }

    /// @inheritdoc BaseTokenWrapperHook
    function _deposit(uint256 underlyingAmount)
        internal
        virtual
        override
        returns (uint256 actualUnderlyingAmount, uint256 wrappedAmount)
    {
        _take(underlyingCurrency, address(this), underlyingAmount);
        // For wrapping, the key is ensuring we wrap exactly what we got
        actualUnderlyingAmount = IStETH(Currency.unwrap(underlyingCurrency)).balanceOf(address(this));

        // Wrap exactly what we have (which might be 1-2 wei less than requested)
        wrappedAmount = wstETH.wrap(actualUnderlyingAmount);
        _settle(wrapperCurrency, address(this), wrappedAmount);
    }

    /// @inheritdoc BaseTokenWrapperHook
    function _withdraw(uint256 wrapperAmount)
        internal
        override
        returns (uint256 actualWrappedAmount, uint256 actualUnwrappedAmount)
    {
        _take(wrapperCurrency, address(this), wrapperAmount);
        actualWrappedAmount = wrapperAmount;
        uint256 unwrappedAmount = wstETH.unwrap(actualWrappedAmount);

        // check pool manager balance to account for balance mismatch on transfers due to rounding errors
        uint256 poolManagerBalanceBefore = IStETH(Currency.unwrap(underlyingCurrency)).balanceOf(address(poolManager));
        _settle(underlyingCurrency, address(this), unwrappedAmount);
        uint256 poolManagerBalanceAfter = IStETH(Currency.unwrap(underlyingCurrency)).balanceOf(address(poolManager));

        actualUnwrappedAmount = poolManagerBalanceAfter - poolManagerBalanceBefore;
    }

    /// @inheritdoc BaseTokenWrapperHook
    /// @notice Calculates how much stETH is needed to receive a specific amount of wstETH
    /// @param wrappedAmount Desired amount of wstETH
    /// @return Amount of stETH required
    /// @dev Uses current stETH/wstETH exchange rate for calculation
    function _getWrapInputRequired(uint256 wrappedAmount) internal view override returns (uint256) {
        return wrappedAmount.divWadUp(wstETH.tokensPerStEth());
    }

    /// @inheritdoc BaseTokenWrapperHook
    /// @notice Calculates how much wstETH is needed to receive a specific amount of stETH
    /// @param underlyingAmount Desired amount of stETH
    /// @return Amount of wstETH required
    /// @dev Uses current stETH/wstETH exchange rate for calculation
    function _getUnwrapInputRequired(uint256 underlyingAmount) internal view override returns (uint256) {
        return wstETH.getWstETHByStETH(underlyingAmount);
    }

    /// @inheritdoc BaseTokenWrapperHook
    function _supportsExactOutput() internal pure override returns (bool) {
        return false;
    }
    
    /// @inheritdoc BaseTokenWrapperHook
    /// @notice Validates stETH/wstETH exchange rates to prevent manipulation
    /// @dev Ensures current exchange rates are within reasonable bounds
    function _validateExchangeRates() internal view override {
        uint256 tokensPerStEth = wstETH.tokensPerStEth();
        
        // Validate the exchange rate is within reasonable bounds
        if (tokensPerStEth < MIN_WSTETH_RATE) {
            InvalidExchangeRate.selector.revertWith();
        }
        
        if (tokensPerStEth > MAX_WSTETH_RATE) {
            ExchangeRateOverflow.selector.revertWith();
        }
        
        // Additional sanity check: ensure the rate is not zero
        if (tokensPerStEth == 0) {
            InvalidExchangeRate.selector.revertWith();
        }
    }
    
    /// @inheritdoc BaseTokenWrapperHook
    /// @notice Enhanced validation for stETH/wstETH exchange rate deviations
    /// @dev Provides specific validation for stETH rebasing token edge cases
    function _validateExchangeRateDeviation(uint256 inputAmount, uint256 outputAmount, bool isWrapping) internal view override {
        // Call parent validation first
        super._validateExchangeRateDeviation(inputAmount, outputAmount, isWrapping);
        
        // Additional stETH-specific validation
        if (isWrapping) {
            // When wrapping stETH to wstETH, ensure the conversion is reasonable
            uint256 expectedWstETH = wstETH.getWstETHByStETH(inputAmount);
            
            // Allow for small rounding differences (0.1% tolerance)
            uint256 tolerance = expectedWstETH / 1000;
            if (outputAmount < expectedWstETH - tolerance || outputAmount > expectedWstETH + tolerance) {
                AmountMismatch.selector.revertWith();
            }
        } else {
            // When unwrapping wstETH to stETH, ensure the conversion is reasonable
            uint256 expectedStETH = inputAmount.mulWadDown(wstETH.tokensPerStEth());
            
            // Allow for small rounding differences (0.1% tolerance)
            uint256 tolerance = expectedStETH / 1000;
            if (outputAmount < expectedStETH - tolerance || outputAmount > expectedStETH + tolerance) {
                AmountMismatch.selector.revertWith();
            }
        }
    }
}
