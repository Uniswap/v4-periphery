// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {SafeTransferLib} from "solmate/utils/SafeTransferLib.sol";
import {ERC20} from "solmate/tokens/ERC20.sol";

/// @notice Library used to interact with PoolManager.sol to settle any open deltas.
/// To settle a positive delta (a credit to the user), a user may take or mint.
/// To settle a negative delta (a debt on the user), a user make transfer or burn to pay off a debt.
/// @dev Note that sync() is called before any erc-20 transfer in `settle`.
library CurrencySettler {
    using SafeTransferLib for ERC20;

    /// @notice Settle (pay) a currency to the PoolManager
    /// @param manager IPoolManager to settle to
    /// @param currency Currency to settle
    /// @param payer Address of the payer, the token sender
    /// @param amount Amount to send
    function settle(IPoolManager manager, Currency currency, address payer, uint256 amount) internal {
        if (currency.isNative()) {
            manager.settle{value: amount}();
        } else {
            manager.sync(currency);
            if (payer != address(this)) {
                ERC20(Currency.unwrap(currency)).safeTransferFrom(payer, address(manager), amount);
            } else {
                ERC20(Currency.unwrap(currency)).safeTransfer(address(manager), amount);
            }
            manager.settle();
        }
    }
}
