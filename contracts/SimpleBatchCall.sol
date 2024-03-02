// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {LockAndBatchCall} from "./base/LockAndBatchCall.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {ImmutableState} from "./base/ImmutableState.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title SimpleBatchCall
/// @notice Implements a naive settle function to perform any arbitrary batch call under one lock to modifyPosition, donate, intitialize, or swap.
contract SimpleBatchCall is LockAndBatchCall {
    using CurrencyLibrary for Currency;

    constructor(IPoolManager _poolManager) ImmutableState(_poolManager) {}

    struct SettleConfig {
        bool withdrawTokens; // If true, takes the underlying ERC20s.
        bool settleUsingTransfer; // If true, sends the underlying ERC20s.
    }

    /// @notice We naively settle all currencies that are touched by the batch call. This data is passed in intially to `execute`.
    function _settle(address sender, bytes memory data) internal override returns (bytes memory settleData) {
        if (data.length != 0) {
            (Currency[] memory currenciesTouched, SettleConfig memory config) =
                abi.decode(data, (Currency[], SettleConfig));

            for (uint256 i = 0; i < currenciesTouched.length; i++) {
                Currency currency = currenciesTouched[i];
                int256 delta = poolManager.currencyDelta(address(this), currenciesTouched[i]);

                if (delta > 0) {
                    if (config.settleUsingTransfer) {
                        ERC20(Currency.unwrap(currency)).transferFrom(sender, address(poolManager), uint256(delta));
                        poolManager.settle(currency);
                    } else {
                        poolManager.safeTransferFrom(
                            address(this), address(poolManager), currency.toId(), uint256(delta), new bytes(0)
                        );
                    }
                }
                if (delta < 0) {
                    if (config.withdrawTokens) {
                        poolManager.mint(currency, address(this), uint256(-delta));
                    } else {
                        poolManager.take(currency, address(this), uint256(-delta));
                    }
                }
            }
        }
    }

    function _handleAfterExecute(bytes memory, /*callReturnData*/ bytes memory /*settleReturnData*/ )
        internal
        pure
        override
    {
        return;
    }
}
