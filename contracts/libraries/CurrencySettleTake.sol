// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IERC20Minimal} from "v4-core/interfaces/external/IERC20Minimal.sol";

library CurrencySettleTake {
    using CurrencyLibrary for Currency;

    function settle(Currency currency, IPoolManager manager, address payer, uint256 amount, bool burn) internal {
        if (currency.isNative()) {
            manager.settle{value: uint128(amount)}(currency);
        } else if (burn) {
            manager.burn(payer, currency.toId(), amount);
        } else {
            IERC20Minimal(Currency.unwrap(currency)).transferFrom(payer, address(manager), uint128(amount));
            manager.settle(currency);
        }
    }

    function take(Currency currency, IPoolManager manager, address recipient, uint256 amount, bool claims) internal {
        claims ? manager.mint(recipient, currency.toId(), amount) : manager.take(currency, recipient, amount);
    }
}
