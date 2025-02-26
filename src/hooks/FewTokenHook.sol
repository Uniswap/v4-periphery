// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {ERC20} from "solmate/src/tokens/ERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {BaseTokenWrapperHook} from "../base/hooks/BaseTokenWrapperHook.sol";
import {IFewWrappedToken} from "../interfaces/external/IFewWrappedToken.sol";

/// @title Wrapped Few Token Hook
/// @notice Hook for wrapping/unwrapping few token in Uniswap V4 pools
/// @dev Implements 1:1 wrapping/unwrapping between token and few token
contract FewTokenHook is BaseTokenWrapperHook {
    /// @notice The fewToken contract used for wrapping/unwrapping operations
    IFewWrappedToken public immutable fewToken;

    /// @notice Creates a new fewToken wrapper hook
    /// @param _manager The Uniswap V4 pool manager
    /// @param _fewToken The fewToken contract address
    /// @dev Initializes with fewToken as wrapper token and token as underlying token
    constructor(IPoolManager _manager, IFewWrappedToken _fewToken)
        BaseTokenWrapperHook(
            _manager,
            Currency.wrap(address(_fewToken)), // wrapper token is fewToken
            Currency.wrap(_fewToken.token()) // underlying token is token
        )
    {
        fewToken = _fewToken;
        ERC20(Currency.unwrap(underlyingCurrency)).approve(address(fewToken), type(uint256).max);
    }

    /// @inheritdoc BaseTokenWrapperHook
    /// @notice Wraps token to fewToken
    /// @param underlyingAmount Amount of token to wrap
    /// @return Amount of fewToken received
    function _deposit(uint256 underlyingAmount) internal override returns (uint256) {
        return fewToken.wrap(underlyingAmount);
    }

    /// @inheritdoc BaseTokenWrapperHook
    /// @notice Unwraps fewToken to token
    /// @param wrapperAmount Amount of fewToken to unwrap
    /// @return Amount of token received
    function _withdraw(uint256 wrapperAmount) internal override returns (uint256) {
        return fewToken.unwrap(wrapperAmount);
    }
}
