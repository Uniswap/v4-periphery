// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title IAmountResolver
/// @author Uniswap Labs
/// @notice Onchain amount resolution for swap-route callback instructions. A Universal Router
///         route is static calldata, so every amount is fixed offchain when the route is built;
///         the proposed `RESOLVE` instruction lets a route obtain a value at execution time via a
///         bounded staticcall to a resolver implementing this interface, and reference the result
///         from a later command's amount field. The margin lending adapters implement it so a
///         route can resolve position-dependent amounts (the live debt a full close must buy, or
///         the live collateral of a supply withdrawal) without an offchain accrual buffer.
/// @dev    Resolvers MUST be pure reads: the caller invokes `resolveAmount` via STATICCALL and
///         copies at most one word of returndata. A resolver controls only WHEN an amount is
///         fixed, never who can move funds; the returned value stays bounded by the route
///         consumer's own caps (allowances, `amountInMaximum`, output-coverage asserts).
interface IAmountResolver {
    /// @notice Resolves an amount at execution time.
    /// @param context Resolver-defined bytes baked into the route at build time. Each implementer
    ///        documents its own context ABI; malformed context reverts.
    /// @return amount The resolved amount, in the relevant token's native decimals.
    function resolveAmount(bytes calldata context) external view returns (uint256 amount);
}
