// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {ILendingAdapter} from "../interfaces/ILendingAdapter.sol";
import {Market} from "../types/Market.sol";
import {Ltv} from "../types/Ltv.sol";

/// @title MarginCalldataDecoder
/// @author Uniswap Labs
/// @notice Decoders for the parameter blobs of margin actions. Each margin action's params are
///         abi-encoded by the router's typed entry points and decoded here before dispatch.
///         `abi.decode` is used deliberately rather than hand-rolled calldata slicing: these params
///         are not on the hottest path and decode safety matters for a fund-routing contract.
library MarginCalldataDecoder {
    /// @notice Decodes `(adapter, market, amount)`. Used by the supply-collateral and repay actions.
    /// @param params ABI-encoded `(ILendingAdapter, Market, uint256)`.
    /// @return adapter The lending adapter.
    /// @return market The (collateral, debt) market descriptor.
    /// @return amount The token amount in the token's native decimals.
    function decodeAdapterMarketAmount(bytes calldata params)
        internal
        pure
        returns (ILendingAdapter adapter, Market memory market, uint256 amount)
    {
        return abi.decode(params, (ILendingAdapter, Market, uint256));
    }

    /// @notice Decodes `(adapter, market, amount, to)`. Used by the withdraw-collateral and borrow
    ///         actions, which require a recipient address.
    /// @param params ABI-encoded `(ILendingAdapter, Market, uint256, address)`.
    /// @return adapter The lending adapter.
    /// @return market The (collateral, debt) market descriptor.
    /// @return amount The token amount in the token's native decimals.
    /// @return to The recipient address; must be the manager or owner (enforced by the account).
    function decodeAdapterMarketAmountReceiver(bytes calldata params)
        internal
        pure
        returns (ILendingAdapter adapter, Market memory market, uint256 amount, address to)
    {
        return abi.decode(params, (ILendingAdapter, Market, uint256, address));
    }

    /// @notice Decodes `(currency, amount, to)`. Used by the sweep action.
    /// @param params ABI-encoded `(Currency, uint256, address)`.
    /// @return currency The ERC-20 token to transfer.
    /// @return amount The amount to transfer in the token's native decimals.
    /// @return to The recipient address; must be the manager or owner (enforced by the account).
    function decodeSweep(bytes calldata params) internal pure returns (Currency currency, uint256 amount, address to) {
        return abi.decode(params, (Currency, uint256, address));
    }

    /// @notice Decodes `(adapter, market, maxLtv)`. Used by the health-assertion action. The account
    ///         is not encoded: the handler always checks the transient active account, never an
    ///         account named in calldata.
    /// @param params ABI-encoded `(ILendingAdapter, Market, Ltv)`.
    /// @return adapter The lending adapter used to query the current LTV.
    /// @return market The (collateral, debt) market descriptor.
    /// @return maxLtv The maximum acceptable LTV (WAD, 1e18 == 100%); zero skips the check.
    function decodeHealthCheck(bytes calldata params)
        internal
        pure
        returns (ILendingAdapter adapter, Market memory market, Ltv maxLtv)
    {
        return abi.decode(params, (ILendingAdapter, Market, Ltv));
    }

    /// @notice Decodes `(currency, minAmount)`. Used by the fill-assertion action to require that an
    ///         exact-output swap delivered at least `minAmount` of `currency`.
    /// @param params ABI-encoded `(Currency, uint256)`.
    /// @return currency The currency whose router credit is checked.
    /// @return minAmount The minimum required credit (the requested exact-output amount).
    function decodeFillCheck(bytes calldata params) internal pure returns (Currency currency, uint256 minAmount) {
        return abi.decode(params, (Currency, uint256));
    }

    /// @notice Decodes `(subId)`. Used by the set-account action to derive the active account from
    ///         the authenticated caller and this sub-account id.
    /// @param params ABI-encoded `(uint256)`.
    /// @return subId The caller's sub-account id.
    function decodeSubId(bytes calldata params) internal pure returns (uint256 subId) {
        return abi.decode(params, (uint256));
    }

    /// @notice Decodes `(currency, amount, payerIsUser)`. Used by the pull-to-account action.
    /// @param params ABI-encoded `(Currency, uint256, bool)`.
    /// @return currency The token to transfer into the active account.
    /// @return amount The amount in the token's native decimals. A `0` amount is rejected by the
    ///         handler (it is not an `OPEN_DELTA` sentinel here); `CONTRACT_BALANCE` is honored only
    ///         when `payerIsUser` is false.
    /// @return payerIsUser True to pull from the caller via Permit2; false to move the router's
    ///         own balance.
    function decodePull(bytes calldata params)
        internal
        pure
        returns (Currency currency, uint256 amount, bool payerIsUser)
    {
        return abi.decode(params, (Currency, uint256, bool));
    }
}
