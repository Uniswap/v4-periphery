// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";

import {IMulticall_v4} from "./IMulticall_v4.sol";

/// @title ISwapAndAdd
/// @notice Route-first liquidity zap for Uniswap v4 (add, rebalance, increase, compound).
///         Enables callers to provide tokens in any ratio—including single-sided or arbitrary non-pool
///         tokens—and end up with a standard PositionManager (POSM) position in a single transaction.
/// @dev Execution Flow:
///      1. Route First: Execute the optional Universal Router `route` to convert surplus tokens toward
///         the deficit side, then measure actual post-route balances.
///      2. Size & Deploy: Compute fee-aware optimistic liquidity from live holdings and pool price. Flash-take
///         any deficit from PoolManager, then mint or increase the position through POSM.
///      3. Reconcile & Trim: Settle deficit with held tokens or a same-pool swap. If a debt remains (due to price
///         impact or fees), trim the newly added liquidity via a partial decrease to cover it.
///      4. Enforce Floor & Sweep: Verify the final post-trim liquidity against `minLiquidity`, sweep all dust
///         and unconsumed funding to `recipient`, and transfer the NFT if newly minted.
///
///      Key Integrator Notes:
///      - Route-First Design: Passing an empty `route` turns the flow into a pure same-pool zap. When a route
///        is provided, post-route balances are used directly so favorable swap execution improves position size.
///      - Route Construction: Routes must specify explicit input amounts. Avoid balance-relative commands
///        (`CONTRACT_BALANCE`, `PAY_PORTION`, bps `SWEEP`), as the zap forwards its entire native balance to the router.
///        Any non-pool route output token (including ETH) must be declared in `routeFunding` (a zero-amount entry works) to be swept to recipient.
///      - Slippage & Operators: `minLiquidity` / `minLiquidityAdded` is the single slippage knob checked on the final
///        position. Constrained operator systems (e.g. keepers) must compute and enforce this floor themselves.
///      - Position Approvals: For `rebalance`, `increase`, and `compound`, caller authorization is checked
///        (owner or approved operator) AND this contract must be ERC-721 approved on the position via POSM
///        (`approve` or `setApprovalForAll`), as POSM authorizes position modifications against the zap as locker.
///      - Operator Trust Model: When an approved operator calls `rebalance`, `increase`, or `compound`, all output
///        (new NFT, cash-out, swept dust) is forced to the position owner to prevent value redirection.
///      - Unsupported Pools: Pools with hooks returning deltas (`BEFORE_SWAP_RETURNS_DELTA`, `AFTER_SWAP_RETURNS_DELTA`,
///        `AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA`, `AFTER_ADD_LIQUIDITY_RETURNS_DELTA`) break settlement conservation
///        and are rejected upfront with `UnsupportedHookPermissions`. Dynamic fee, gating, and oracle hooks are supported.
///      - Known Limits: Fee-on-transfer and rebasing tokens are unsupported (atomic reverts or larger trim, never token loss).
///        Budgets within the pool's ~1-wei mint/burn rounding toll cannot settle and revert `InsufficientLiquidity`.
///      - HookData Reuse: The same `hookData` payload is passed to all hook callbacks in the operation; single-use
///        payload schemes are unsupported.
///      - Multicall & Native ETH: Supports multicall with Permit2 forwarding (`permitBatch` + op). Because all subcalls
///        share `msg.value`, an ETH-bearing batch fails, even if combined with ERC20-only subcalls. Zero-value batches compose 
///        freely across multiple positions; batch native operations using WETH or separate transactions.
interface ISwapAndAdd is IMulticall_v4 {
    /// @notice Emitted when a new position is minted via `add`.
    event Added(
        address indexed recipient,
        uint256 indexed tokenId,
        address caller,
        uint128 liquidity,
        uint256 amount0,
        uint256 amount1
    );

    /// @notice Emitted when an existing position is burned and redeployed into a new range via `rebalance`.
    event Rebalanced(
        address indexed recipient,
        uint256 indexed oldTokenId,
        uint256 indexed newTokenId,
        address caller,
        uint128 liquidity,
        uint256 amount0,
        uint256 amount1
    );

    /// @notice Emitted when an existing position is topped up in place via `increase`.
    event Increased(
        address indexed recipient,
        uint256 indexed tokenId,
        address caller,
        uint128 liquidityAdded,
        uint256 amount0,
        uint256 amount1
    );

    /// @notice Emitted when accrued fees are reinvested in place via `compound`.
    event Compounded(
        address indexed recipient,
        uint256 indexed tokenId,
        address caller,
        uint128 liquidityAdded,
        uint256 amount0,
        uint256 amount1
    );

    /// @notice Thrown when a required address argument is address(0).
    error ZeroAddress();

    /// @notice Thrown when the transaction is executed after the specified deadline.
    error DeadlinePassed(uint256 deadline);

    /// @notice Thrown when `msg.value` does not match the operation's expected native amount or native balance is insufficient.
    error InvalidEthValue();

    /// @notice Thrown when ETH is received from an unauthorized sender (only PoolManager, POSM, and Universal Router allowed).
    error InvalidEthSender();

    /// @notice Thrown when the resulting position liquidity is below the caller's minimum liquidity threshold.
    error InsufficientLiquidity(uint256 minLiquidity, uint128 liquidity);

    /// @notice Thrown when the recipient is address(0) or this contract.
    error InvalidRecipient(address recipient);

    /// @notice Thrown when caller is neither the position owner nor an approved operator.
    error NotAuthorizedForToken(uint256 tokenId);

    /// @notice Thrown when a negative delta in `rebalance` requests to withdraw more than the position's holdings.
    error ReturnExceedsWithdrawn(uint256 requested, uint256 withdrawn);

    /// @notice Thrown when compounding or fee-only increase has no fees or budget to deploy.
    error NoFeesToCompound();

    /// @notice Thrown when `routeFunding` is provided without a `route`.
    error RouteFundingRequiresRoute();

    /// @notice Thrown when a `routeFunding` token is one of the pool currencies (use `amount0In`/`amount1In` instead).
    error InvalidFundingToken(Currency token);

    /// @notice Thrown when the pool's hook carries a returns-delta permission (see the Unsupported Pools note).
    error UnsupportedHookPermissions(IHooks hooks);

    /// @notice Represents a non-pool token amount pulled to fund an off-chain route.
    /// @param token The non-pool token address (or address(0) for native ETH).
    /// @param amount The amount to pull from caller via Permit2 (or expected msg.value for native ETH). A zero amount pulls nothing but sweeps unlisted donations of that token.
    struct TokenAmount {
        Currency token;
        uint256 amount;
    }

    /// @notice Parameters for `add`.
    /// @param poolKey Target Uniswap v4 pool.
    /// @param tickLower Lower tick of the position range.
    /// @param tickUpper Upper tick of the position range.
    /// @param amount0In Amount of token0 budget to pull from caller (can be 0).
    /// @param amount1In Amount of token1 budget to pull from caller (can be 0).
    /// @param minLiquidity Minimum liquidity required for the minted position (slippage floor).
    /// @param recipient Address that receives the minted position NFT and leftover dust.
    /// @param deadline Timestamp after which the transaction will revert.
    /// @param route Encoded Universal Router commands and inputs (empty for pure same-pool zap). Must scope input amounts explicitly (never spend entire contract balance).
    /// @param routeFunding Optional non-pool tokens pulled to fund the route. Unused amounts are swept to `recipient`.
    /// @param hookData Arbitrary data passed to pool hooks (reused across all callbacks).
    struct AddParams {
        PoolKey poolKey;
        int24 tickLower;
        int24 tickUpper;
        uint256 amount0In;
        uint256 amount1In;
        uint256 minLiquidity;
        address recipient;
        uint256 deadline;
        bytes route;
        TokenAmount[] routeFunding;
        bytes hookData;
    }

    /// @notice Create a new v4 position from a one- or two-sided token budget in a single transaction.
    /// @param params The configuration parameters for the add operation.
    /// @return tokenId The minted POSM position ID.
    /// @return liquidity The final liquidity of the minted position.
    /// @return amount0 Amount of token0 deposited into the position.
    /// @return amount1 Amount of token1 deposited into the position.
    function add(AddParams calldata params)
        external
        payable
        returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1);

    /// @notice Parameters for `increase`.
    /// @param tokenId Existing position ID to increase.
    /// @param amount0In Amount of token0 budget to pull from caller (can be 0). Accrued fees are collected and reinvested automatically.
    /// @param amount1In Amount of token1 budget to pull from caller (can be 0). Accrued fees are collected and reinvested automatically.
    /// @param minLiquidityAdded Minimum liquidity that must be added to the position (slippage floor).
    /// @param recipient Destination for swept dust. Forced to position owner if caller is an operator.
    /// @param deadline Timestamp after which the transaction will revert.
    /// @param route Encoded Universal Router commands and inputs (can be empty).
    /// @param routeFunding Optional non-pool tokens pulled to fund the route. Unused amounts are swept to `recipient`.
    /// @param hookData Arbitrary data passed to pool hooks.
    struct IncreaseParams {
        uint256 tokenId;
        uint256 amount0In;
        uint256 amount1In;
        uint256 minLiquidityAdded;
        address recipient;
        uint256 deadline;
        bytes route;
        TokenAmount[] routeFunding;
        bytes hookData;
    }

    /// @notice Top up an existing position with a one- or two-sided budget and reinvest accrued fees in a single transaction.
    /// @dev Caller must be owner or approved operator, and this contract must be ERC-721 approved on POSM for `tokenId`.
    /// @param params The configuration parameters for the increase operation.
    /// @return liquidityAdded The liquidity added to the position.
    /// @return amount0 Amount of token0 added to the position.
    /// @return amount1 Amount of token1 added to the position.
    function increase(IncreaseParams calldata params)
        external
        payable
        returns (uint128 liquidityAdded, uint256 amount0, uint256 amount1);

    /// @notice Parameters for `rebalance`.
    /// @param tokenId Existing position ID to withdraw, burn, and redeploy.
    /// @param additional0 Signed delta for token0: positive pulls additional tokens, negative returns withdrawn tokens, zero redeploys full withdrawn balance.
    /// @param additional1 Signed delta for token1 with the same signed delta semantics.
    /// @param newTickLower Lower tick of the new position range.
    /// @param newTickUpper Upper tick of the new position range.
    /// @param minLiquidity Minimum liquidity required for the newly minted position (slippage floor).
    /// @param recipient Destination for the new position NFT, returned cash-out tokens, and dust. Forced to owner if caller is an operator.
    /// @param deadline Timestamp after which the transaction will revert.
    /// @param route Encoded Universal Router commands and inputs (can be empty).
    /// @param routeFunding Optional non-pool tokens pulled to fund the route. Unused amounts are swept to `recipient`.
    /// @param hookData Arbitrary data passed to pool hooks.
    struct RebalanceParams {
        uint256 tokenId;
        int128 additional0;
        int128 additional1;
        int24 newTickLower;
        int24 newTickUpper;
        uint256 minLiquidity;
        address recipient;
        uint256 deadline;
        bytes route;
        TokenAmount[] routeFunding;
        bytes hookData;
    }

    /// @notice Withdraw an existing position entirely and redeploy it into a new tick range, optionally adding or cashing out tokens.
    /// @dev Caller must be owner or approved operator, and this contract must be ERC-721 approved on POSM for `tokenId`.
    /// @param params The configuration parameters for the rebalance operation.
    /// @return newTokenId The minted position ID in the new range.
    /// @return liquidity The final liquidity of the new position.
    /// @return amount0 Amount of token0 deposited into the new position.
    /// @return amount1 Amount of token1 deposited into the new position.
    function rebalance(RebalanceParams calldata params)
        external
        payable
        returns (uint256 newTokenId, uint128 liquidity, uint256 amount0, uint256 amount1);

    /// @notice Parameters for `compound`.
    /// @param tokenId Existing position ID whose accrued fees will be collected and reinvested.
    /// @param minLiquidityAdded Minimum liquidity that must be added from reinvested fees (slippage floor).
    /// @param recipient Destination for swept dust. Forced to position owner if caller is an operator.
    /// @param deadline Timestamp after which the transaction will revert.
    /// @param route Encoded Universal Router commands and inputs (can be empty).
    /// @param hookData Arbitrary data passed to pool hooks.
    struct CompoundParams {
        uint256 tokenId;
        uint256 minLiquidityAdded;
        address recipient;
        uint256 deadline;
        bytes route;
        bytes hookData;
    }

    /// @notice Collect accrued fees on a position and reinvest them back into the same position in a single transaction.
    /// @dev Caller must be owner or approved operator, and this contract must be ERC-721 approved on POSM for `tokenId`.
    /// @param params The configuration parameters for the compound operation.
    /// @return liquidityAdded The liquidity added to the position from reinvested fees.
    /// @return amount0 Amount of token0 reinvested into the position.
    /// @return amount1 Amount of token1 reinvested into the position.
    function compound(CompoundParams calldata params)
        external
        returns (uint128 liquidityAdded, uint256 amount0, uint256 amount1);
}
