// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {CurrencySettleTake} from "./CurrencySettleTake.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IERC20Minimal} from "v4-core/interfaces/external/IERC20Minimal.sol";

/// @notice Library used to send Currencies from address to address
library CurrencySenderLibrary {
    using CurrencyLibrary for Currency;
    using CurrencySettleTake for Currency;

    /// @notice Send a custodied Currency to a recipient
    /// @dev If sending ERC20 or native, the PoolManager must be unlocked
    /// @param currency The Currency to send
    /// @param manager The PoolManager
    /// @param recipient The recipient address
    /// @param amount The amount to send
    /// @param useClaims If true, transfer ERC-6909 tokens
    function send(Currency currency, IPoolManager manager, address recipient, uint256 amount, bool useClaims)
        internal
    {
        if (useClaims) {
            manager.transfer(recipient, currency.toId(), amount);
        } else {
            manager.burn(address(this), currency.toId(), amount);
            currency.take(manager, recipient, amount, false);
        }
    }
}
