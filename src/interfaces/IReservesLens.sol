// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/// @title ReservesLens interface
/// @notice Computes the token amounts represented by a v4 pool's aggregate core liquidity curve
/// @dev Core amounts are liquidity principal at the current price. They exclude uncollected LP fees, protocol fees,
///      donations, and hook-managed assets. Hook-reported reserves and effective liquidity are returned separately and
///      must not be treated as core-derived values. Calls are intended to use an explicit RPC block tag when results are
///      stored or compared over time.
interface IReservesLens {
    /// @notice Status of optional URC-3 hook statistics
    /// @dev DIRECT means the resolved provider is the hook itself (whether resolved from address(0) or passed
    ///      explicitly); EXTERNAL means a distinct third-party provider. INSUFFICIENT_GAS means the probe was not
    ///      attempted because remaining gas could not guarantee the stats stipends after the EIP-150 63/64 reduction;
    ///      core fields are still valid and the caller can retry with more gas to obtain hook statistics.
    enum HookStatsStatus {
        NO_HOOK,
        NOT_SUPPORTED,
        DIRECT,
        EXTERNAL,
        INVALID_PROVIDER,
        CALL_FAILED,
        INVALID_RESPONSE,
        INSUFFICIENT_GAS
    }

    /// @notice Complete pool liquidity-TVL snapshot
    struct PoolTVL {
        /// @notice Fee-excluded token0 principal derived from PoolManager liquidity state
        uint256 coreAmount0;
        /// @notice Fee-excluded token1 principal derived from PoolManager liquidity state
        uint256 coreAmount1;
        /// @notice Hook-reported token0 assets under management; meaningful only for DIRECT or EXTERNAL status
        uint256 hookReserves0;
        /// @notice Hook-reported token1 assets under management; meaningful only for DIRECT or EXTERNAL status
        uint256 hookReserves1;
        /// @notice Hook-reported token0 liquidity immediately available to swap
        uint256 hookEffective0;
        /// @notice Hook-reported token1 liquidity immediately available to swap
        uint256 hookEffective1;
        /// @notice Pool sqrt price used for the core calculation
        uint160 sqrtPriceX96;
        /// @notice Pool tick used for the core calculation
        int24 tick;
        /// @notice Active core liquidity stored by PoolManager
        uint128 activeLiquidity;
        /// @notice Block number at which this snapshot was evaluated
        uint256 blockNumber;
        /// @notice URC-3 provider queried for hook statistics, if any
        address statsProvider;
        /// @notice The fourteen v4 permission bits decoded from the hook address
        uint16 hookPermissions;
        /// @notice Whether any return-delta permission bit permits custom accounting
        bool hasCustomAccounting;
        /// @notice Availability and provenance of the hook-reported fields
        HookStatsStatus statsStatus;
    }

    /// @notice Initialized tick data compatible with the v3 TickLens field layout
    struct PopulatedTick {
        int24 tick;
        int128 liquidityNet;
        uint128 liquidityGross;
    }

    /// @notice Thrown when the pool identified by the supplied key is not initialized
    error PoolNotInitialized(PoolId poolId);

    /// @notice Thrown when tick spacing is outside v4-core bounds
    error InvalidTickSpacing(int24 tickSpacing);

    /// @notice Thrown when a paged-call work budget is outside supported bounds
    error InvalidScanBudget(uint32 maxReads);

    /// @notice Thrown when remaining gas cannot guarantee a hook-stats gas stipend after the EIP-150 63/64 reduction
    /// @dev Backstop only: gas headroom for the ERC165 probes and all stats calls is checked up front and reported as
    ///      INSUFFICIENT_GAS status, so this error should be unreachable. It exists so that a budgeting mistake can
    ///      never gas-starve a healthy provider and misreport it as CALL_FAILED.
    error InsufficientGasForHookStats();

    /// @notice Thrown when the supplied manager returns a malformed response to a batched extsload
    error ManagerBatchReadFailed(address manager, bytes32 firstSlot, bytes32 lastSlot, uint256 count);

    /// @notice Thrown when reconstructed liquidity is inconsistent with PoolManager state
    error LiquidityInvariantFailed(PoolId poolId);

    /// @notice Thrown when an initialized tick is inconsistent with its bitmap entry or pool bounds
    error TickInvariantFailed(PoolId poolId, int256 tick);

    /// @notice Thrown when a continuation cursor has an invalid encoding
    error InvalidCursor();

    /// @notice Thrown when a continuation cursor version is unsupported
    error UnsupportedCursorVersion(uint8 version);

    /// @notice Thrown when a cursor is used with a different chain, manager, or pool
    error CursorContextMismatch();

    /// @notice Thrown when pages are evaluated at different blocks
    error CursorBlockMismatch(uint256 expected, uint256 actual);

    /// @notice Thrown when parallel batch inputs have different lengths
    error InputLengthMismatch();

    /// @notice Computes the complete pool snapshot in one call
    /// @dev The full initialized-tick domain is scanned. Bitmap-word reads alone cost ~32M gas for a tick-spacing-one
    ///      pool even when it is empty, which exceeds a 30M block-style gas limit (though most providers cap eth_call
    ///      higher, e.g. geth's 50M default); use getPoolTVLPaged for small tick spacings or providers with low
    ///      simulation gas limits.
    /// @param manager PoolManager whose state is read. The caller is responsible for selecting the canonical manager.
    /// @param key Complete pool key emitted by PoolManager.Initialize
    /// @param statsProvider Optional external URC-3 provider, or address(0) to probe the hook directly
    /// @return result Fee-excluded core amounts and separately labeled optional hook statistics
    function getPoolTVL(IPoolManager manager, PoolKey calldata key, address statsProvider)
        external
        view
        returns (PoolTVL memory result);

    /// @notice Computes complete snapshots for multiple pools on one PoolManager
    /// @dev One expensive pool reverts the complete batch. Prefer independent RPC calls for large or untrusted batches.
    /// @param manager PoolManager whose state is read
    /// @param keys Complete pool keys
    /// @param statsProviders One optional URC-3 provider per key; use address(0) to probe each hook directly
    function getPoolTVLBatch(IPoolManager manager, PoolKey[] calldata keys, address[] calldata statsProviders)
        external
        view
        returns (PoolTVL[] memory results);

    /// @notice Returns all initialized ticks in one compressed bitmap word
    /// @dev Field layout mirrors v3 TickLens, adapted to a v4 PoolManager and PoolKey.
    function getPopulatedTicksInWord(IPoolManager manager, PoolKey calldata key, int16 wordPos)
        external
        view
        returns (PopulatedTick[] memory populatedTicks);

    /// @notice Computes a bounded portion of a pool snapshot
    /// @dev Pass an empty cursor to start and pass returned cursors unchanged. All pages must use the same explicit block
    ///      tag. Intermediate results are incomplete and must not be treated as TVL. Cursor provenance cannot be
    ///      authenticated by this stateless contract, so pagination is intended for offchain callers.
    /// @param manager PoolManager whose state is read
    /// @param key Complete pool key emitted by PoolManager.Initialize
    /// @param statsProvider Optional external URC-3 provider, or address(0) to probe the hook directly
    /// @param cursor Empty to start or the exact opaque cursor returned by the prior page
    /// @param maxReads Approximate bitmap/tick storage-read work budget for this page
    /// @return result Complete only when done is true
    /// @return nextCursor Opaque continuation cursor, empty when done is true
    /// @return done Whether the complete result has been produced
    function getPoolTVLPaged(
        IPoolManager manager,
        PoolKey calldata key,
        address statsProvider,
        bytes calldata cursor,
        uint32 maxReads
    ) external view returns (PoolTVL memory result, bytes memory nextCursor, bool done);
}
