// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {WETH} from "solmate/src/tokens/WETH.sol";
import {ERC20} from "solmate/src/tokens/ERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {BaseTokenWrapperHook} from "../base/hooks/BaseTokenWrapperHook.sol";
import {IFewWrappedToken} from "../interfaces/external/IFewWrappedToken.sol";

/// @title Wrapped Few ETH Hook
/// @notice Hook for wrapping/unwrapping fwWETH in Uniswap V4 pools
/// @dev Implements 1:1 wrapping/unwrapping between ETH and fwWETH
contract FewETHHook is BaseTokenWrapperHook {
    /// @notice The WETH9 contract
    WETH public immutable weth;
    /// @notice The fwWETH contract used for wrapping/unwrapping operations
    IFewWrappedToken public immutable fwWETH;

    /// @notice Creates a new fwWETH wrapper hook
    /// @param _manager The Uniswap V4 pool manager
    /// @param _weth The WETH9 contract address
    /// @param _fwWETH The fwWETH contract address
    /// @dev Initializes with fwWETH as wrapper token and ETH as underlying token
    constructor(IPoolManager _manager, address payable _weth, IFewWrappedToken _fwWETH)
        BaseTokenWrapperHook(
            _manager,
            Currency.wrap(address(_fwWETH)), // wrapper token is fwWETH
            CurrencyLibrary.ADDRESS_ZERO // underlying token is ETH (address(0))
        )
    {
        weth = WETH(payable(_weth));
        fwWETH = _fwWETH;
        ERC20(weth).approve(address(fwWETH), type(uint256).max);
    }

    /// @inheritdoc BaseTokenWrapperHook
    /// @notice Wraps ETH to fwWETH
    /// @param underlyingAmount Amount of ETH to wrap
    /// @return Amount of fwWETH received
    function _deposit(uint256 underlyingAmount) internal override returns (uint256) {
        weth.deposit{value: underlyingAmount}();
        return fwWETH.wrap(underlyingAmount);
    }

    /// @inheritdoc BaseTokenWrapperHook
    /// @notice Unwraps fwWETH to ETH
    /// @param wrapperAmount Amount of fwWETH to unwrap
    /// @return Amount of ETH received
    function _withdraw(uint256 wrapperAmount) internal override returns (uint256) {
        fwWETH.unwrap(wrapperAmount);
        weth.withdraw(wrapperAmount);
        return wrapperAmount;
    }

    /// @notice Required to receive ETH
    receive() external payable {}
}
