// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {WETH} from "solmate/src/tokens/WETH.sol";
import {BaseTokenWrapperHook} from "../base/hooks/BaseTokenWrapperHook.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";

/// @title Wrapped Ether Hook
/// @notice Hook for wrapping/unwrapping ETH in Uniswap V4 pools
/// @dev Implements 1:1 wrapping/unwrapping of ETH to WETH
contract WETHHook is BaseTokenWrapperHook {
    using CustomRevert for bytes4;

    /// @notice The WETH9 contract
    WETH public immutable weth;

    /// @notice Creates a new WETH wrapper hook
    /// @param _manager The Uniswap V4 pool manager
    /// @param _weth The WETH9 contract address
    constructor(IPoolManager _manager, address payable _weth)
        BaseTokenWrapperHook(
            _manager,
            Currency.wrap(_weth), // wrapper token is WETH
            CurrencyLibrary.ADDRESS_ZERO // underlying token is ETH (address(0))
        )
    {
        weth = WETH(payable(_weth));
    }

    /// @inheritdoc BaseTokenWrapperHook
    /// @dev Note the WETH deposit relies on the WETH wrapper having a receive function that mints WETH to msg.sender
    function _deposit(uint256 underlyingAmount) internal override returns (uint256, uint256) {
        // Sync WETH on PoolManager
        poolManager.sync(wrapperCurrency);
        // take ETH from PoolManager and deposit directly into the WETH contract
        // this will mint WETH to msg.sender (PoolManager in this case)
        _take(underlyingCurrency, address(weth), underlyingAmount);
        // Settle on PoolManager which will take into account the new weth
        poolManager.settle();
        return (underlyingAmount, underlyingAmount); // 1:1 ratio
    }

    /// @inheritdoc BaseTokenWrapperHook
    function _withdraw(uint256 wrapperAmount) internal override returns (uint256, uint256) {
        // take WETH into this hook contract
        _take(wrapperCurrency, address(this), wrapperAmount);
        // Withdraw WETH - this returns ETH back to this hook contract
        weth.withdraw(wrapperAmount);
        _settle(underlyingCurrency, address(this), wrapperAmount);
        return (wrapperAmount, wrapperAmount); // 1:1 ratio
    }

    /// @inheritdoc BaseTokenWrapperHook
    /// @notice WETH exchange rate validation (always 1:1)
    /// @dev Ensures WETH contract is functioning properly
    function _validateExchangeRates() internal view override {
        // WETH should always maintain 1:1 ratio with ETH
        // Additional validation could include checking WETH contract state
        // For now, we just ensure the WETH contract exists and has code
        if (address(weth).code.length == 0) {
            InvalidExchangeRate.selector.revertWith();
        }
    }
    
    /// @inheritdoc BaseTokenWrapperHook
    /// @notice Enhanced validation for ETH/WETH 1:1 conversion
    /// @dev Ensures exactly 1:1 ratio is maintained
    function _validateExchangeRateDeviation(uint256 inputAmount, uint256 outputAmount, bool) internal pure override {
        // For WETH, input and output should always be exactly equal (1:1 ratio)
        if (inputAmount != outputAmount) {
            AmountMismatch.selector.revertWith();
        }
        
        // Prevent zero amounts
        if (inputAmount == 0 || outputAmount == 0) {
            AmountMismatch.selector.revertWith();
        }
    }

    /// @notice Required to receive ETH
    receive() external payable {}
}
