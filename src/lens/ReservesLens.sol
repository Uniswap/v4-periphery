// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {ERC165Checker} from "openzeppelin-contracts/contracts/utils/introspection/ERC165Checker.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {BitMath} from "@uniswap/v4-core/src/libraries/BitMath.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IReservesLens} from "../interfaces/IReservesLens.sol";
import {IHookStats} from "../interfaces/external/IHookStats.sol";

/// @title ReservesLens
/// @notice Stateless view contract for v4 core liquidity TVL and optional URC-3 hook statistics
/// @dev Reconstructs the aggregate liquidity curve by walking initialized ticks in ascending order, applying each
///      liquidityNet, and using core SqrtPriceMath for every nonzero-liquidity interval. Raw PoolManager state is read
///      through extsload; this contract is therefore coupled to the StateLibrary storage layout of compatible v4
///      PoolManager deployments. The PoolManager is supplied per call so constructor-free bytecode can be deployed at
///      the same deterministic address on every compatible chain. Callers are responsible for selecting the canonical
///      PoolManager and obtaining the complete PoolKey from its Initialize event.
contract ReservesLens is IReservesLens {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    uint8 private constant CURSOR_VERSION = 1;
    uint256 private constant CURSOR_LENGTH = 15 * 32;
    uint32 private constant MIN_PAGE_READS = 2;
    uint32 private constant MAX_PAGE_READS = 4096;
    /// @dev Page budget used when the caller passes maxReads == 0; ~2M gas per page fits any eth_call limit
    uint32 private constant DEFAULT_PAGE_READS = 512;
    uint256 private constant BITMAP_BATCH_SIZE = 256;
    uint256 private constant HOOK_STATS_GAS_LIMIT = 500_000;
    /// @dev ERC165Checker issues at most three 30k-gas probes before the interface is trusted
    uint256 private constant ERC165_PROBE_GAS = 90_000;
    /// @dev Gas that must remain before probing hook stats: the ERC165 probes, three bounded stats calls, and local
    ///      overhead between them, grossed up so EIP-150's 63/64 forwarding rule cannot starve any single call
    uint256 private constant HOOK_STATS_GAS_BUDGET = ((3 * HOOK_STATS_GAS_LIMIT + ERC165_PROBE_GAS + 15_000) * 64) / 63;
    uint160 private constant ALL_HOOK_MASK = (1 << 14) - 1;
    uint16 private constant CUSTOM_ACCOUNTING_MASK = (1 << 4) - 1;

    struct ScanState {
        uint8 version;
        uint256 blockNumber;
        bytes32 contextHash;
        uint160 sqrtPriceX96;
        int24 currentTick;
        uint128 activeLiquidity;
        int16 wordPos;
        uint16 bitPos;
        bool hasPreviousTick;
        int24 previousTick;
        uint128 runningLiquidity;
        uint256 amount0;
        uint256 amount1;
        bool observedCurrentLiquidity;
        uint128 currentLiquidity;
    }

    enum StaticCallStatus {
        SUCCESS,
        FAILED,
        INVALID_RESPONSE
    }

    /// @inheritdoc IReservesLens
    function getPoolTVL(IPoolManager manager, PoolKey calldata key) external view returns (PoolTVL memory result) {
        return _getPoolTVL(manager, key, address(0));
    }

    /// @inheritdoc IReservesLens
    function getPoolTVL(IPoolManager manager, PoolKey calldata key, address statsProvider)
        external
        view
        returns (PoolTVL memory result)
    {
        return _getPoolTVL(manager, key, statsProvider);
    }

    /// @inheritdoc IReservesLens
    function getPoolTVLBatch(IPoolManager manager, PoolKey[] calldata keys)
        external
        view
        returns (PoolTVL[] memory results)
    {
        results = new PoolTVL[](keys.length);
        for (uint256 i; i < keys.length; i++) {
            results[i] = _getPoolTVL(manager, keys[i], address(0));
        }
    }

    /// @inheritdoc IReservesLens
    function getPoolTVLBatch(IPoolManager manager, PoolKey[] calldata keys, address[] calldata statsProviders)
        external
        view
        returns (PoolTVL[] memory results)
    {
        if (keys.length != statsProviders.length) revert InputLengthMismatch();
        results = new PoolTVL[](keys.length);
        for (uint256 i; i < keys.length; i++) {
            results[i] = _getPoolTVL(manager, keys[i], statsProviders[i]);
        }
    }

    /// @inheritdoc IReservesLens
    function getPopulatedTicksInWord(IPoolManager manager, PoolKey calldata key, int16 wordPos)
        external
        view
        returns (PopulatedTick[] memory populatedTicks)
    {
        PoolId poolId = key.toId();
        _initialize(manager, key.tickSpacing, poolId);
        uint256 bitmap = manager.getTickBitmap(poolId, wordPos);
        uint256 remaining = bitmap;
        uint256 count;
        while (remaining != 0) {
            count++;
            remaining &= remaining - 1;
        }

        populatedTicks = new PopulatedTick[](count);
        for (uint256 i; bitmap != 0; i++) {
            uint8 bit = BitMath.leastSignificantBit(bitmap);
            populatedTicks[i] = _readPopulatedTick(manager, poolId, key.tickSpacing, wordPos, bit);
            bitmap &= bitmap - 1;
        }
    }

    function _getPoolTVL(IPoolManager manager, PoolKey calldata key, address statsProvider)
        private
        view
        returns (PoolTVL memory result)
    {
        PoolId poolId = key.toId();
        ScanState memory state = _initialize(manager, key.tickSpacing, poolId);
        state = _scanComplete(manager, key.tickSpacing, poolId, state);
        result = _result(state, key);
        _readHookStats(result, key, statsProvider);
    }

    /// @inheritdoc IReservesLens
    function getPoolTVLPaged(IPoolManager manager, PoolKey calldata key, bytes calldata cursor)
        external
        view
        returns (PoolTVL memory result, bytes memory nextCursor, bool done)
    {
        return _getPoolTVLPaged(manager, key, address(0), cursor, DEFAULT_PAGE_READS);
    }

    /// @inheritdoc IReservesLens
    function getPoolTVLPaged(
        IPoolManager manager,
        PoolKey calldata key,
        address statsProvider,
        bytes calldata cursor,
        uint32 maxReads
    ) external view returns (PoolTVL memory result, bytes memory nextCursor, bool done) {
        if (maxReads == 0) maxReads = DEFAULT_PAGE_READS;
        return _getPoolTVLPaged(manager, key, statsProvider, cursor, maxReads);
    }

    function _getPoolTVLPaged(
        IPoolManager manager,
        PoolKey calldata key,
        address statsProvider,
        bytes calldata cursor,
        uint32 maxReads
    ) private view returns (PoolTVL memory result, bytes memory nextCursor, bool done) {
        if (maxReads < MIN_PAGE_READS || maxReads > MAX_PAGE_READS) revert InvalidScanBudget(maxReads);

        PoolId poolId = key.toId();
        ScanState memory state;
        if (cursor.length == 0) {
            state = _initialize(manager, key.tickSpacing, poolId);
        } else {
            if (cursor.length != CURSOR_LENGTH) revert InvalidCursor();
            state = abi.decode(cursor, (ScanState));
            if (state.version != CURSOR_VERSION) revert UnsupportedCursorVersion(state.version);
            if (state.contextHash != _contextHash(manager, poolId)) revert CursorContextMismatch();
            if (state.blockNumber != block.number) revert CursorBlockMismatch(state.blockNumber, block.number);
            if (state.bitPos > 256) revert InvalidCursor();
            _verifyCursorSnapshot(manager, poolId, state);
        }

        (state, done) = _scan(manager, key.tickSpacing, poolId, state, maxReads);
        result = _result(state, key);
        if (done) {
            _readHookStats(result, key, statsProvider);
        } else {
            nextCursor = abi.encode(state);
        }
    }

    function _initialize(IPoolManager manager, int24 tickSpacing, PoolId poolId)
        private
        view
        returns (ScanState memory state)
    {
        if (tickSpacing < TickMath.MIN_TICK_SPACING || tickSpacing > TickMath.MAX_TICK_SPACING) {
            revert InvalidTickSpacing(tickSpacing);
        }

        (uint160 sqrtPriceX96, int24 currentTick,,) = manager.getSlot0(poolId);
        if (sqrtPriceX96 == 0) revert PoolNotInitialized(poolId);

        uint128 activeLiquidity = manager.getLiquidity(poolId);
        int24 minCompressed = TickMath.minUsableTick(tickSpacing) / tickSpacing;

        state = ScanState({
            version: CURSOR_VERSION,
            blockNumber: block.number,
            contextHash: _contextHash(manager, poolId),
            sqrtPriceX96: sqrtPriceX96,
            currentTick: currentTick,
            activeLiquidity: activeLiquidity,
            wordPos: int16(minCompressed >> 8),
            bitPos: 0,
            hasPreviousTick: false,
            previousTick: 0,
            runningLiquidity: 0,
            amount0: 0,
            amount1: 0,
            observedCurrentLiquidity: false,
            currentLiquidity: 0
        });
    }

    function _scan(IPoolManager manager, int24 tickSpacing, PoolId poolId, ScanState memory state, uint32 maxReads)
        private
        view
        returns (ScanState memory, bool done)
    {
        int16 maxWord = _maxWord(tickSpacing);
        uint32 reads;

        while (state.wordPos <= maxWord) {
            if (reads >= maxReads) return (state, false);

            uint256 bitmap = manager.getTickBitmap(poolId, state.wordPos);
            reads++;
            // resume mid-word; a shift of 256 yields zero, so a bitPos-256 cursor skips the word entirely
            if (state.bitPos != 0) bitmap &= type(uint256).max << state.bitPos;

            bool wordDone;
            (reads, wordDone) = _processWord(manager, tickSpacing, poolId, state, bitmap, reads, maxReads);
            if (!wordDone) return (state, false);

            state.wordPos = int16(int256(state.wordPos) + 1);
            state.bitPos = 0;
        }

        _validateComplete(poolId, state);
        return (state, true);
    }

    function _scanComplete(IPoolManager manager, int24 tickSpacing, PoolId poolId, ScanState memory state)
        private
        view
        returns (ScanState memory)
    {
        int16 maxWord = _maxWord(tickSpacing);
        int256 nextWord = state.wordPos;

        while (nextWord <= maxWord) {
            uint256 remaining = uint256(int256(maxWord) - nextWord + 1);
            uint256 count = remaining < BITMAP_BATCH_SIZE ? remaining : BITMAP_BATCH_SIZE;
            bytes32[] memory slots = new bytes32[](count);
            for (uint256 i; i < count; i++) {
                slots[i] = _tickBitmapSlot(poolId, int16(nextWord + int256(i)));
            }
            bytes32[] memory bitmaps = manager.extsload(slots);
            if (bitmaps.length != count) {
                revert ManagerBatchReadFailed(address(manager), slots[0], slots[count - 1], count);
            }

            for (uint256 i; i < count; i++) {
                state.wordPos = int16(nextWord + int256(i));
                _processWord(manager, tickSpacing, poolId, state, uint256(bitmaps[i]), 0, type(uint32).max);
            }
            nextWord += int256(count);
        }

        state.wordPos = int16(int256(maxWord) + 1);
        state.bitPos = 0;
        _validateComplete(poolId, state);
        return state;
    }

    /// @dev Processes every initialized tick in one bitmap word, charging one read per tick against the budget.
    ///      Returns done=false with state.bitPos positioned on the unprocessed bit when the budget is exhausted.
    function _processWord(
        IPoolManager manager,
        int24 tickSpacing,
        PoolId poolId,
        ScanState memory state,
        uint256 bitmap,
        uint32 reads,
        uint32 maxReads
    ) private view returns (uint32, bool done) {
        while (bitmap != 0) {
            uint8 bit = BitMath.leastSignificantBit(bitmap);
            if (reads >= maxReads) {
                state.bitPos = bit;
                return (reads, false);
            }
            _processInitializedTick(manager, tickSpacing, poolId, state, bit);
            reads++;
            bitmap &= bitmap - 1;
            state.bitPos = uint16(bit) + 1;
        }
        return (reads, true);
    }

    function _maxWord(int24 tickSpacing) private pure returns (int16) {
        return int16((TickMath.maxUsableTick(tickSpacing) / tickSpacing) >> 8);
    }

    function _validateComplete(PoolId poolId, ScanState memory state) private pure {
        if (state.runningLiquidity != 0) revert LiquidityInvariantFailed(poolId);
        uint128 reconstructed = state.observedCurrentLiquidity ? state.currentLiquidity : 0;
        if (reconstructed != state.activeLiquidity) revert LiquidityInvariantFailed(poolId);
    }

    function _processInitializedTick(
        IPoolManager manager,
        int24 tickSpacing,
        PoolId poolId,
        ScanState memory state,
        uint8 bit
    ) private view {
        int24 minTick = TickMath.minUsableTick(tickSpacing);
        int24 maxTick = TickMath.maxUsableTick(tickSpacing);
        int256 compressed = int256(state.wordPos) * 256 + int256(uint256(bit));
        int256 tickValue = compressed * int256(tickSpacing);
        if (tickValue < minTick || tickValue > maxTick) revert TickInvariantFailed(poolId, tickValue);

        int24 tick = int24(tickValue);
        (, int128 liquidityNet) = _readTick(manager, poolId, tick);
        if (liquidityNet == 0) return;

        if (state.hasPreviousTick) _accumulateInterval(state, state.previousTick, tick);
        state.runningLiquidity = _addLiquidity(poolId, state.runningLiquidity, liquidityNet);
        state.previousTick = tick;
        state.hasPreviousTick = true;
    }

    function _accumulateInterval(ScanState memory state, int24 tickA, int24 tickB) private pure {
        if (state.currentTick >= tickA && state.currentTick < tickB) {
            state.currentLiquidity = state.runningLiquidity;
            state.observedCurrentLiquidity = true;
        }
        if (state.runningLiquidity == 0) return;

        uint160 sqrtA = TickMath.getSqrtPriceAtTick(tickA);
        uint160 sqrtB = TickMath.getSqrtPriceAtTick(tickB);
        if (state.currentTick < tickA) {
            state.amount0 += SqrtPriceMath.getAmount0Delta(sqrtA, sqrtB, state.runningLiquidity, false);
        } else if (state.currentTick < tickB) {
            state.amount0 += SqrtPriceMath.getAmount0Delta(state.sqrtPriceX96, sqrtB, state.runningLiquidity, false);
            state.amount1 += SqrtPriceMath.getAmount1Delta(sqrtA, state.sqrtPriceX96, state.runningLiquidity, false);
        } else {
            state.amount1 += SqrtPriceMath.getAmount1Delta(sqrtA, sqrtB, state.runningLiquidity, false);
        }
    }

    function _addLiquidity(PoolId poolId, uint128 liquidity, int128 delta) private pure returns (uint128 next) {
        int256 value = int256(uint256(liquidity)) + int256(delta);
        if (value < 0 || uint256(value) > type(uint128).max) revert LiquidityInvariantFailed(poolId);
        next = uint128(uint256(value));
    }

    function _result(ScanState memory state, PoolKey calldata key) private pure returns (PoolTVL memory result) {
        address hook = address(key.hooks);
        result.coreAmount0 = state.amount0;
        result.coreAmount1 = state.amount1;
        result.sqrtPriceX96 = state.sqrtPriceX96;
        result.tick = state.currentTick;
        result.activeLiquidity = state.activeLiquidity;
        result.blockNumber = state.blockNumber;
        result.hookPermissions = uint16(uint160(hook) & ALL_HOOK_MASK);
        result.hasCustomAccounting = result.hookPermissions & CUSTOM_ACCOUNTING_MASK != 0;
        result.statsStatus = hook == address(0) ? HookStatsStatus.NO_HOOK : HookStatsStatus.NOT_SUPPORTED;
    }

    function _readTick(IPoolManager manager, PoolId poolId, int24 tick)
        private
        view
        returns (uint128 liquidityGross, int128 liquidityNet)
    {
        (liquidityGross, liquidityNet) = manager.getTickLiquidity(poolId, tick);
        if (liquidityGross == 0) revert TickInvariantFailed(poolId, tick);
    }

    function _readPopulatedTick(IPoolManager manager, PoolId poolId, int24 tickSpacing, int16 wordPos, uint8 bit)
        private
        view
        returns (PopulatedTick memory populated)
    {
        int256 tickValue = (int256(wordPos) * 256 + int256(uint256(bit))) * int256(tickSpacing);
        if (tickValue < TickMath.minUsableTick(tickSpacing) || tickValue > TickMath.maxUsableTick(tickSpacing)) {
            revert TickInvariantFailed(poolId, tickValue);
        }
        populated.tick = int24(tickValue);
        (populated.liquidityGross, populated.liquidityNet) = _readTick(manager, poolId, populated.tick);
    }

    function _readHookStats(PoolTVL memory result, PoolKey calldata key, address suppliedProvider) private view {
        address hook = address(key.hooks);
        if (hook == address(0)) {
            result.statsStatus = HookStatsStatus.NO_HOOK;
            return;
        }

        address provider = suppliedProvider == address(0) ? hook : suppliedProvider;
        result.statsProvider = provider;

        // A gas-starved ERC165 probe or stats call fails in a way indistinguishable from a provider fault, so the
        // reported status would depend on the caller's gas budget instead of on-chain state. Check headroom for the
        // whole probe sequence up front and degrade to INSUFFICIENT_GAS; core fields are already populated.
        if (gasleft() < HOOK_STATS_GAS_BUDGET) {
            result.statsStatus = HookStatsStatus.INSUFFICIENT_GAS;
            return;
        }

        if (!ERC165Checker.supportsInterface(provider, type(IHookStats).interfaceId)) {
            result.statsStatus = provider == hook ? HookStatsStatus.NOT_SUPPORTED : HookStatsStatus.INVALID_PROVIDER;
            return;
        }

        (StaticCallStatus hookStatus, bytes32 hookWord,) =
            _boundedStaticcall(provider, abi.encodeCall(IHookStats.hook, ()), 32);
        if (hookStatus != StaticCallStatus.SUCCESS) {
            result.statsStatus = _hookFailureStatus(hookStatus);
            return;
        }
        uint256 reportedHook = uint256(hookWord);
        if (reportedHook > type(uint160).max || address(uint160(reportedHook)) != hook) {
            result.statsStatus = HookStatsStatus.INVALID_PROVIDER;
            return;
        }

        (StaticCallStatus reservesStatus, bytes32 reserves0, bytes32 reserves1) =
            _boundedStaticcall(provider, abi.encodeCall(IHookStats.getReserves, (key)), 64);
        if (reservesStatus != StaticCallStatus.SUCCESS) {
            result.statsStatus = _hookFailureStatus(reservesStatus);
            return;
        }

        (StaticCallStatus effectiveStatus, bytes32 effective0, bytes32 effective1) =
            _boundedStaticcall(provider, abi.encodeCall(IHookStats.getEffectiveLiquidity, (key)), 64);
        if (effectiveStatus != StaticCallStatus.SUCCESS) {
            result.statsStatus = _hookFailureStatus(effectiveStatus);
            return;
        }

        result.hookReserves0 = uint256(reserves0);
        result.hookReserves1 = uint256(reserves1);
        result.hookEffective0 = uint256(effective0);
        result.hookEffective1 = uint256(effective1);
        if (result.hookEffective0 > result.hookReserves0 || result.hookEffective1 > result.hookReserves1) {
            result.hookReserves0 = 0;
            result.hookReserves1 = 0;
            result.hookEffective0 = 0;
            result.hookEffective1 = 0;
            result.statsStatus = HookStatsStatus.INVALID_RESPONSE;
            return;
        }

        result.statsStatus = provider == hook ? HookStatsStatus.DIRECT : HookStatsStatus.EXTERNAL;
    }

    function _hookFailureStatus(StaticCallStatus status) private pure returns (HookStatsStatus) {
        return status == StaticCallStatus.FAILED ? HookStatsStatus.CALL_FAILED : HookStatsStatus.INVALID_RESPONSE;
    }

    /// @dev Bounds untrusted provider calls to HOOK_STATS_GAS_LIMIT so a malicious provider cannot consume the
    ///      caller's whole budget. EIP-150 forwards at most 63/64 of remaining gas, so the requested limit is only
    ///      honored when enough gas remains. HOOK_STATS_GAS_BUDGET is checked before the probe sequence starts, so
    ///      this guard is an unreachable backstop: if budgeting is ever wrong it reverts rather than let a starved
    ///      provider be misclassified as CALL_FAILED.
    function _boundedStaticcall(address target, bytes memory input, uint256 expectedSize)
        private
        view
        returns (StaticCallStatus status, bytes32 word0, bytes32 word1)
    {
        if (gasleft() < (HOOK_STATS_GAS_LIMIT * 64) / 63 + 1_000) revert InsufficientGasForHookStats();

        bool success;
        uint256 returnSize;
        assembly ("memory-safe") {
            let output := mload(0x40)
            mstore(output, 0)
            mstore(add(output, 0x20), 0)
            success := staticcall(HOOK_STATS_GAS_LIMIT, target, add(input, 0x20), mload(input), output, 0x40)
            returnSize := returndatasize()
            word0 := mload(output)
            word1 := mload(add(output, 0x20))
        }
        if (!success) return (StaticCallStatus.FAILED, bytes32(0), bytes32(0));
        if (returnSize != expectedSize) return (StaticCallStatus.INVALID_RESPONSE, bytes32(0), bytes32(0));
        return (StaticCallStatus.SUCCESS, word0, word1);
    }

    function _contextHash(IPoolManager manager, PoolId poolId) private view returns (bytes32) {
        return keccak256(abi.encode(block.chainid, address(manager), PoolId.unwrap(poolId)));
    }

    /// @dev Anchors a resumed cursor's snapshot fields to live manager state. The scan-position and amount
    ///      accumulator fields are inherently caller-trusted (only a rescan could validate them), but price, tick,
    ///      and active liquidity are cheap to re-read, so a resumed page can never return forged snapshot metadata
    ///      and same-block state drift (e.g. pages evaluated against a pending tag) fails loudly here instead of
    ///      surfacing as a downstream invariant error attributed to the pool.
    function _verifyCursorSnapshot(IPoolManager manager, PoolId poolId, ScanState memory state) private view {
        (uint160 sqrtPriceX96, int24 currentTick,,) = manager.getSlot0(poolId);
        if (sqrtPriceX96 == 0) revert PoolNotInitialized(poolId);
        if (
            sqrtPriceX96 != state.sqrtPriceX96 || currentTick != state.currentTick
                || manager.getLiquidity(poolId) != state.activeLiquidity
        ) revert CursorStateMismatch();
    }

    /// @dev Raw slot for pools[poolId].tickBitmap[wordPos], for the batched extsload in _scanComplete; single-word
    ///      reads go through StateLibrary getters instead
    function _tickBitmapSlot(PoolId poolId, int16 wordPos) private pure returns (bytes32) {
        bytes32 mappingSlot = bytes32(uint256(StateLibrary._getPoolStateSlot(poolId)) + StateLibrary.TICK_BITMAP_OFFSET);
        return keccak256(abi.encodePacked(int256(wordPos), mappingSlot));
    }
}
