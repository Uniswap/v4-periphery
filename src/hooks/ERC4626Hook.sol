// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {ERC20} from "solmate/src/tokens/ERC20.sol";
import {ERC4626} from "solmate/src/mixins/ERC4626.sol";
import {BaseTokenWrapperHook} from "../base/hooks/BaseTokenWrapperHook.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

/// @title ERC4626 Tokenized Vault Hook
/// @notice Hook for wrapping/unwrapping assets to/from an ERC4626 vault via Uniswap V4 pools
/// @dev Implements dynamic exchange rate wrapping/unwrapping between ERC4626 shares and assets
contract ERC4626Hook is BaseTokenWrapperHook {
    /// @notice The ERC4626 vault contract
    ERC4626 public immutable vault;

    /// @notice Creates a new ERC4626 wrapper hook
    /// @param _manager The Uniswap V4 pool manager
    /// @param _vault The ERC4626 vault contract address
    /// @dev Initializes with the ERC4626 vault as wrapper token and the ERC4626 underlying asset as underlying token
    constructor(IPoolManager _manager, ERC4626 _vault)
        BaseTokenWrapperHook(
            _manager,
            Currency.wrap(address(_vault)), // wrapper token is the ERC4626 vault itself
            Currency.wrap(address(_vault.asset())) // underlying token is the underlying asset of ERC4626 vault
        )
    {
        vault = _vault;
        ERC20(Currency.unwrap(underlyingCurrency)).approve(address(vault), type(uint256).max);
    }

    /// @inheritdoc BaseTokenWrapperHook
    /// @notice Wraps assets to shares in the ERC4626 vault
    /// @param underlyingAmount Amount of assets to wrap
    /// @return Amount of shares received
    function _deposit(uint256 underlyingAmount) internal override returns (uint256) {
        return vault.deposit({assets: underlyingAmount, receiver: address(this)});
    }

    /// @inheritdoc BaseTokenWrapperHook
    /// @notice Unwraps shares to assets in the ERC4626 vault
    /// @param wrappedAmount Amount of shares to unwrap
    /// @return Amount of assets received
    function _withdraw(uint256 wrappedAmount) internal override returns (uint256) {
        return vault.redeem({shares: wrappedAmount, receiver: address(this), owner: address(this)});
    }

    /// @inheritdoc BaseTokenWrapperHook
    /// @notice Calculates how much assets are needed to receive a specific amount of shares
    /// @param wrappedAmount Desired amount of shares
    /// @return Amount of assets required
    /// @dev Uses current ERC4626 shares-to-assets exchange rate for calculation
    function _getWrapInputRequired(uint256 wrappedAmount) internal view override returns (uint256) {
        return vault.convertToAssets({shares: wrappedAmount});
    }

    /// @inheritdoc BaseTokenWrapperHook
    /// @notice Calculates how much shares are needed to receive a specific amount of assets
    /// @param underlyingAmount Desired amount of assets
    /// @return Amount of shares required
    /// @dev Uses current ERC4626 assets-to-shares exchange rate for calculation
    function _getUnwrapInputRequired(uint256 underlyingAmount) internal view override returns (uint256) {
        return vault.convertToShares({assets: underlyingAmount});
    }
}
