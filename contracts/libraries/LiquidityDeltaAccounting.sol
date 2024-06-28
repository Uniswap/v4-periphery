// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";

import "forge-std/console2.sol";

library LiquidityDeltaAccounting {
    function split(BalanceDelta liquidityDelta, BalanceDelta callerFeesAccrued, BalanceDelta totalFeesAccrued)
        internal
        returns (BalanceDelta callerDelta, BalanceDelta thisDelta)
    {
        if (totalFeesAccrued == callerFeesAccrued) {
            // when totalFeesAccrued == callerFeesAccrued, the caller is not sharing the range
            // therefore, the caller is responsible for the entire liquidityDelta
            callerDelta = liquidityDelta;
        } else {
            // the delta for increasing liquidity assuming that totalFeesAccrued was not applied
            BalanceDelta principalDelta = liquidityDelta - totalFeesAccrued;

            // outstanding deltas the caller is responsible for, after their fees are credited to the principal delta
            callerDelta = principalDelta + callerFeesAccrued;

            // outstanding deltas this contract is responsible for, intuitively the contract is responsible for taking fees external to the caller's accrued fees
            thisDelta = totalFeesAccrued - callerFeesAccrued;
        }
    }
}
