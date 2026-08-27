// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";

import {IMulticall_v4} from "./IMulticall_v4.sol";

/// @title ISwapAndAdd
/// @notice Turns a token budget in any ratio into a POSM position in one transaction.
///         Operations: add, rebalance, increase, compound.
/// @dev Flow: execute the optional Universal Router `route`, size liquidity from held balances,
///      flash-take any deficit, deploy through POSM, settle via a same-pool swap, trim the new
///      liquidity for any remaining debt, check `minLiquidity`, sweep dust to `recipient`.
///
///      Integration surface:
///      - Routes must use explicit input amounts. Balance-relative commands are unsafe because the
///        zap forwards its full native balance to the router.
///      - Non-pool route outputs must appear in `routeFunding` to be swept. A zero amount is enough.
///      - `minLiquidity` / `minLiquidityAdded` is the only slippage check, applied post-trim.
///      - rebalance / increase / compound: the caller must be the owner or an approved operator,
///        and this contract needs ERC-721 approval on the position in POSM. Operator calls send
///        all output to the owner, though operators remain trusted since they set the `route` and
///        `minLiquidity` (and already have full custody on POSM).
///      - Hooks with returns-delta permissions are rejected. Fee-on-transfer and rebasing tokens
///        are unsupported. The same `hookData` goes to every hook callback.
///      - Multicall batches carry at most one native-ETH operation because all subcalls share
///        `msg.value`; adding further operations reverts. Zero-value batches compose freely. Batch
///        native operations using WETH or separate transactions.
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

    /// @notice Emitted when a position is burned and redeployed into a new range via `rebalance`.
    event Rebalanced(
        address indexed recipient,
        uint256 indexed oldTokenId,
        uint256 indexed newTokenId,
        address caller,
        uint128 liquidity,
        uint256 amount0,
        uint256 amount1
    );

    /// @notice Emitted when a position is topped up in place via `increase`.
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

    /// @notice Thrown when the transaction executes after the deadline.
    error DeadlinePassed(uint256 deadline);

    /// @notice Thrown when `msg.value` does not match the expected native amount.
    error InvalidEthValue();

    /// @notice Thrown when ETH arrives from a sender other than PoolManager, POSM, or Universal Router.
    error InvalidEthSender();

    /// @notice Thrown when the final position liquidity is below the caller's minimum.
    error InsufficientLiquidity(uint256 minLiquidity, uint128 liquidity);

    /// @notice Thrown when the recipient is address(0) or this contract.
    error InvalidRecipient(address recipient);

    /// @notice Thrown when the caller is neither the position owner nor an approved operator.
    error NotAuthorizedForToken(uint256 tokenId);

    /// @notice Thrown when a negative delta in `rebalance` requests more than the withdrawn amount.
    error ReturnExceedsWithdrawn(uint256 requested, uint256 withdrawn);

    /// @notice Thrown when a compound or fee-only increase has no fees and no budget to deploy.
    error NoFeesToCompound();

    /// @notice Thrown when `routeFunding` is provided without a `route`.
    error RouteFundingRequiresRoute();

    /// @notice Thrown when a `routeFunding` token is a pool currency.
    error InvalidFundingToken(Currency token);

    /// @notice Thrown when the pool's hook carries a returns-delta permission.
    error UnsupportedHookPermissions(IHooks hooks);

    /// @notice A non-pool token amount pulled to fund the route.
    /// @param token The token address, or address(0) for native ETH.
    /// @param amount The amount to pull via Permit2, or the expected msg.value for native ETH.
    ///               A zero amount pulls nothing but still marks the token for the sweep.
    struct TokenAmount {
        Currency token;
        uint256 amount;
    }

    /// @notice Parameters for `add`.
    /// @param poolKey Target pool.
    /// @param tickLower Lower tick of the range.
    /// @param tickUpper Upper tick of the range.
    /// @param amount0In Token0 to pull from the caller. Can be 0.
    /// @param amount1In Token1 to pull from the caller. Can be 0.
    /// @param minLiquidity Minimum liquidity of the minted position (slippage floor).
    /// @param recipient Receives the position NFT and dust.
    /// @param deadline Timestamp after which the transaction reverts.
    /// @param route Encoded Universal Router commands and inputs. Empty for a same-pool zap.
    /// @param routeFunding Non-pool tokens pulled to fund the route.
    /// @param hookData Data passed to every hook callback.
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

    /// @notice Creates a new v4 position from a one- or two-sided token budget.
    /// @param params The add parameters.
    /// @return tokenId The minted position ID.
    /// @return liquidity The final liquidity of the minted position.
    /// @return amount0 Token0 deposited into the position.
    /// @return amount1 Token1 deposited into the position.
    function add(AddParams calldata params)
        external
        payable
        returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1);

    /// @notice Parameters for `increase`.
    /// @param tokenId Position ID to increase.
    /// @param amount0In Token0 to pull from the caller. Can be 0.
    /// @param amount1In Token1 to pull from the caller. Can be 0.
    /// @param minLiquidityAdded Minimum liquidity the operation must add (slippage floor).
    /// @param recipient Receives dust. Forced to the owner if the caller is an operator.
    /// @param deadline Timestamp after which the transaction reverts.
    /// @param route Encoded Universal Router commands and inputs. Can be empty.
    /// @param routeFunding Non-pool tokens pulled to fund the route.
    /// @param hookData Data passed to every hook callback.
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

    /// @notice Tops up a position with a one- or two-sided budget and reinvests accrued fees.
    /// @dev Requires caller authorization and ERC-721 approval on the position in POSM.
    /// @param params The increase parameters.
    /// @return liquidityAdded The liquidity added.
    /// @return amount0 Token0 added to the position.
    /// @return amount1 Token1 added to the position.
    function increase(IncreaseParams calldata params)
        external
        payable
        returns (uint128 liquidityAdded, uint256 amount0, uint256 amount1);

    /// @notice Parameters for `rebalance`.
    /// @param tokenId Position ID to burn and redeploy.
    /// @param additional0 Signed token0 delta. Positive pulls extra tokens, negative cashes out,
    ///                    zero redeploys the full withdrawn balance.
    /// @param additional1 Signed token1 delta with the same semantics.
    /// @param newTickLower Lower tick of the new range.
    /// @param newTickUpper Upper tick of the new range.
    /// @param minLiquidity Minimum liquidity of the new position (slippage floor).
    /// @param recipient Receives the new NFT, cash-out, and dust. Forced to the owner if the
    ///                  caller is an operator.
    /// @param deadline Timestamp after which the transaction reverts.
    /// @param route Encoded Universal Router commands and inputs. Can be empty.
    /// @param routeFunding Non-pool tokens pulled to fund the route.
    /// @param hookData Data passed to every hook callback.
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

    /// @notice Withdraws a position fully and redeploys it into a new tick range.
    /// @dev Requires caller authorization and ERC-721 approval on the position in POSM.
    /// @param params The rebalance parameters.
    /// @return newTokenId The minted position ID in the new range.
    /// @return liquidity The final liquidity of the new position.
    /// @return amount0 Token0 deposited into the new position.
    /// @return amount1 Token1 deposited into the new position.
    function rebalance(RebalanceParams calldata params)
        external
        payable
        returns (uint256 newTokenId, uint128 liquidity, uint256 amount0, uint256 amount1);

    /// @notice Parameters for `compound`.
    /// @param tokenId Position ID whose fees are collected and reinvested.
    /// @param minLiquidityAdded Minimum liquidity the reinvested fees must add (slippage floor).
    /// @param recipient Receives dust. Forced to the owner if the caller is an operator.
    /// @param deadline Timestamp after which the transaction reverts.
    /// @param route Encoded Universal Router commands and inputs. Can be empty.
    /// @param hookData Data passed to every hook callback.
    struct CompoundParams {
        uint256 tokenId;
        uint256 minLiquidityAdded;
        address recipient;
        uint256 deadline;
        bytes route;
        bytes hookData;
    }

    /// @notice Collects accrued fees on a position and reinvests them into the same position.
    /// @dev Requires caller authorization and ERC-721 approval on the position in POSM.
    /// @param params The compound parameters.
    /// @return liquidityAdded The liquidity added from reinvested fees.
    /// @return amount0 Token0 reinvested into the position.
    /// @return amount1 Token1 reinvested into the position.
    function compound(CompoundParams calldata params)
        external
        returns (uint128 liquidityAdded, uint256 amount0, uint256 amount1);
}
