// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.20;

import "../libraries/SwapIntention.sol";
import {BalanceDelta} from "@uniswap/v4-core/contracts/types/BalanceDelta.sol";
import {IPoolManager} from "@uniswap/v4-core/contracts/interfaces/IPoolManager.sol";
import {Currency} from "@uniswap/v4-core/contracts/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/contracts/types/PoolKey.sol";

interface IQuoter {
    error InvalidQuoteType();
    error InvalidQuoteTypeInRevert();
    error UnexpectedRevertBytes();

    struct NonZeroDeltaCurrency {
        Currency currency;
        int128 deltaAmount;
    }

    function quoteExactInputSingle(ExactInputSingleParams calldata params)
        external
        returns (int128[] memory deltaAmounts, uint160 sqrtPriceX96After, uint32 initializedTicksCrossed);

    function quoteExactInput(ExactInputParams memory params)
        external
        returns (
            int128[] memory deltaAmounts,
            uint160[] memory sqrtPriceX96AfterList,
            uint32[] memory initializedTicksCrossedList
        );
}
