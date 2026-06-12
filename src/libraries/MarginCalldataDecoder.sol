// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {ILendingAdapter} from "../interfaces/ILendingAdapter.sol";
import {Market} from "../types/Market.sol";
import {Ltv} from "../types/Ltv.sol";

/// @notice Decoders for the parameter blobs of margin actions. Each margin action's params are
///         abi-encoded by the router's typed entry points and decoded here before dispatch. abi
///         decoding is used deliberately rather than hand-rolled calldata slicing: these params are
///         not the hottest path and decode safety matters for a fund-routing contract.
library MarginCalldataDecoder {
    /// @notice (adapter, market, amount), used by supply-collateral and repay.
    function decodeAdapterMarketAmount(bytes calldata params)
        internal
        pure
        returns (ILendingAdapter adapter, Market memory market, uint256 amount)
    {
        return abi.decode(params, (ILendingAdapter, Market, uint256));
    }

    /// @notice (adapter, market, amount, to), used by withdraw-collateral and borrow.
    function decodeAdapterMarketAmountReceiver(bytes calldata params)
        internal
        pure
        returns (ILendingAdapter adapter, Market memory market, uint256 amount, address to)
    {
        return abi.decode(params, (ILendingAdapter, Market, uint256, address));
    }

    /// @notice (currency, amount, to), used by sweep.
    function decodeSweep(bytes calldata params)
        internal
        pure
        returns (Currency currency, uint256 amount, address to)
    {
        return abi.decode(params, (Currency, uint256, address));
    }

    /// @notice (adapter, market, account, maxLtv), used by the health assertion.
    function decodeHealthCheck(bytes calldata params)
        internal
        pure
        returns (ILendingAdapter adapter, Market memory market, address account, Ltv maxLtv)
    {
        return abi.decode(params, (ILendingAdapter, Market, address, Ltv));
    }
}
