// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {LockAndBatchCall} from "./base/LockAndBatchCall.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {ImmutableState} from "./base/ImmutableState.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import {CurrencySettler} from "@uniswap/v4-core/test/utils/CurrencySettler.sol";

/// @title SimpleBatchCall
/// @notice Implements a naive settle function to perform any arbitrary batch call under one lock to modifyPosition, donate, intitialize, or swap.
contract SimpleBatchCall is LockAndBatchCall {
    using CurrencyLibrary for Currency;
    using TransientStateLibrary for IPoolManager;
    using CurrencySettler for Currency;

    constructor(IPoolManager _poolManager) ImmutableState(_poolManager) {}

    struct SettleConfig {
        bool takeClaims;
        bool settleUsingBurn; // If true, sends the underlying ERC20s.
    }

    /// @notice We naively settle all currencies that are touched by the batch call. This data is passed in intially to `execute`.
    function _settle(address sender, bytes memory data) internal override returns (bytes memory settleData) {
        if (data.length != 0) {
            (Currency[] memory currenciesTouched, SettleConfig memory config) =
                abi.decode(data, (Currency[], SettleConfig));

            for (uint256 i = 0; i < currenciesTouched.length; i++) {
                Currency currency = currenciesTouched[i];
                int256 delta = poolManager.currencyDelta(address(this), currenciesTouched[i]);

                if (delta < 0) {
                    currency.settle(poolManager, sender, uint256(-delta), config.settleUsingBurn);
                }
                if (delta > 0) {
                    currency.take(poolManager, address(this), uint256(delta), config.takeClaims);
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
