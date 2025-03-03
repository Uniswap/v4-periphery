// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {WETH} from "solmate/src/tokens/WETH.sol";
import {BaseTokenWrapperHook} from "../base/hooks/BaseTokenWrapperHook.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";

/// @title Wrapped Ether Hook
/// @notice Hook for wrapping/unwrapping ETH in Uniswap V4 pools
/// @dev Implements 1:1 wrapping/unwrapping of ETH to WETH
contract WETHHook is BaseTokenWrapperHook {
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
    function _deposit(uint256 underlyingAmount) internal override returns (uint256) {
        weth.deposit{value: underlyingAmount}();
        return underlyingAmount; // 1:1 ratio
    }

    /// @inheritdoc BaseTokenWrapperHook
    function _withdraw(uint256 wrapperAmount) internal override returns (uint256) {
        weth.withdraw(wrapperAmount);
        return wrapperAmount; // 1:1 ratio
    }

    /// @notice Required to receive ETH
    receive() external payable {}
}
