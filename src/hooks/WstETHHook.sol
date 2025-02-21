// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {ERC20} from "solmate/src/tokens/ERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {BaseTokenWrapperHook} from "../base/hooks/BaseTokenWrapperHook.sol";
import {IWstETH} from "../interfaces/external/IWstETH.sol";

/// @title Wrapped Staked ETH (wstETH) Hook
/// @notice Hook for wrapping/unwrapping stETH/wstETH in Uniswap V4 pools
/// @dev Implements dynamic exchange rate wrapping/unwrapping between stETH and wstETH
/// @dev wstETH represents stETH with accrued staking rewards, maintaining a dynamic exchange rate
contract WstETHHook is BaseTokenWrapperHook {
    /// @notice The wstETH contract used for wrapping/unwrapping operations
    IWstETH public immutable wstETH;

    /// @notice Creates a new wstETH wrapper hook
    /// @param _manager The Uniswap V4 pool manager
    /// @param _wsteth The wstETH contract address
    /// @dev Initializes with wstETH as wrapper token and stETH as underlying token
    constructor(IPoolManager _manager, IWstETH _wsteth)
        BaseTokenWrapperHook(
            _manager,
            Currency.wrap(address(_wsteth)), // wrapper token is wsteth
            Currency.wrap(_wsteth.stETH()) // underlying token is stETH
        )
    {
        wstETH = _wsteth;
        ERC20(Currency.unwrap(underlyingCurrency)).approve(address(wstETH), type(uint256).max);
    }

    /// @inheritdoc BaseTokenWrapperHook
    /// @notice Wraps stETH to wstETH
    /// @param underlyingAmount Amount of stETH to wrap
    /// @return Amount of wstETH received
    function _deposit(uint256 underlyingAmount) internal override returns (uint256) {
        return wstETH.wrap(underlyingAmount);
    }

    /// @inheritdoc BaseTokenWrapperHook
    /// @notice Unwraps wstETH to stETH
    /// @param wrapperAmount Amount of wstETH to unwrap
    /// @return Amount of stETH received
    function _withdraw(uint256 wrapperAmount) internal override returns (uint256) {
        return wstETH.unwrap(wrapperAmount);
    }

    /// @inheritdoc BaseTokenWrapperHook
    /// @notice Calculates how much stETH is needed to receive a specific amount of wstETH
    /// @param wrappedAmount Desired amount of wstETH
    /// @return Amount of stETH required
    /// @dev Uses current stETH/wstETH exchange rate for calculation
    function _getWrapInputRequired(uint256 wrappedAmount) internal view override returns (uint256) {
        return wstETH.getStETHByWstETH(wrappedAmount);
    }

    /// @inheritdoc BaseTokenWrapperHook
    /// @notice Calculates how much wstETH is needed to receive a specific amount of stETH
    /// @param underlyingAmount Desired amount of stETH
    /// @return Amount of wstETH required
    /// @dev Uses current stETH/wstETH exchange rate for calculation
    function _getUnwrapInputRequired(uint256 underlyingAmount) internal view override returns (uint256) {
        return wstETH.getWstETHByStETH(underlyingAmount);
    }
}
