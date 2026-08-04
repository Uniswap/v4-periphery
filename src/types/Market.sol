// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

/// @title Market
/// @author Uniswap Labs
/// @notice The lending-protocol-agnostic market descriptor: the `(collateral, debt)` token pair.
/// @dev Token-pair-only by design: there is no `marketId` field. The singleton lending adapter
///      resolves the pair to a concrete protocol market internally.
/// @param collateral The ERC-20 token used as collateral in the lending market.
/// @param debt The ERC-20 token borrowed as debt in the lending market.
struct Market {
    Currency collateral;
    Currency debt;
}
