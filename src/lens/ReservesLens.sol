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

/// @notice Single-overload views of IExtsload so selectors are compile-time-checked; Solidity cannot
///         disambiguate the overloaded extsload members for .selector or abi.encodeCall
interface IExtsloadWord {
    function extsload(bytes32 slot) external view returns (bytes32 value);
}

interface IExtsloadSparse {
    function extsload(bytes32[] calldata slots) external view returns (bytes32[] memory values);
}

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

    uint8 private constant CURSOR_VERSION = 1;
    uint256 private constant CURSOR_LENGTH = 15 * 32;
    uint32 private constant MIN_PAGE_READS = 2;
    uint32 private constant MAX_PAGE_READS = 4096;
    uint256 private constant BITMAP_BATCH_SIZE = 256;
    uint256 private constant HOOK_STATS_GAS_LIMIT = 500_000;
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
    function getPoolTVL(IPoolManager manager, PoolKey calldata key, address statsProvider)
        external
        view
        returns (PoolTVL memory result)
    {
        return _getPoolTVL(manager, key, statsProvider);
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
        uint256 bitmap = uint256(_readWord(address(manager), _tickBitmapSlot(poolId, wordPos)));
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
    function getPoolTVLPaged(
        IPoolManager manager,
        PoolKey calldata key,
        address statsProvider,
        bytes calldata cursor,
        uint32 maxReads
    ) external view returns (PoolTVL memory result, bytes memory nextCursor, bool done) {
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

        bytes32 poolStateSlot = _poolStateSlot(poolId);
        bytes32 slot0 = _readWord(address(manager), poolStateSlot);
        uint160 sqrtPriceX96;
        int24 currentTick;
        assembly ("memory-safe") {
            sqrtPriceX96 := and(slot0, 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF)
            currentTick := signextend(2, shr(160, slot0))
        }
        if (sqrtPriceX96 == 0) revert PoolNotInitialized(poolId);

        uint128 activeLiquidity = uint128(
            uint256(_readWord(address(manager), bytes32(uint256(poolStateSlot) + StateLibrary.LIQUIDITY_OFFSET)))
        );
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
        int24 maxTick = TickMath.maxUsableTick(tickSpacing);
        int16 maxWord = int16((maxTick / tickSpacing) >> 8);
        uint32 reads;

        while (state.wordPos <= maxWord) {
            if (reads >= maxReads) return (state, false);

            uint256 bitmap = uint256(_readWord(address(manager), _tickBitmapSlot(poolId, state.wordPos)));
            reads++;

            if (state.bitPos == 256) {
                state.wordPos = int16(int256(state.wordPos) + 1);
                state.bitPos = 0;
                continue;
            }
            if (state.bitPos != 0) bitmap &= type(uint256).max << state.bitPos;

            while (bitmap != 0) {
                uint8 bit = BitMath.leastSignificantBit(bitmap);
                if (reads >= maxReads) {
                    state.bitPos = bit;
                    return (state, false);
                }
                _processInitializedTick(manager, tickSpacing, poolId, state, bit);
                reads++;
                bitmap &= bitmap - 1;
                state.bitPos = uint16(bit) + 1;
            }

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
        int24 maxTick = TickMath.maxUsableTick(tickSpacing);
        int16 maxWord = int16((maxTick / tickSpacing) >> 8);
        int256 nextWord = state.wordPos;

        while (nextWord <= maxWord) {
            uint256 remaining = uint256(int256(maxWord) - nextWord + 1);
            uint256 count = remaining < BITMAP_BATCH_SIZE ? remaining : BITMAP_BATCH_SIZE;
            bytes32[] memory slots = new bytes32[](count);
            for (uint256 i; i < count; i++) {
                slots[i] = _tickBitmapSlot(poolId, int16(nextWord + int256(i)));
            }
            bytes32[] memory bitmaps = _readWords(address(manager), slots);

            for (uint256 i; i < count; i++) {
                state.wordPos = int16(nextWord + int256(i));
                uint256 bitmap = uint256(bitmaps[i]);
                while (bitmap != 0) {
                    uint8 bit = BitMath.leastSignificantBit(bitmap);
                    _processInitializedTick(manager, tickSpacing, poolId, state, bit);
                    bitmap &= bitmap - 1;
                }
            }
            nextWord += int256(count);
        }

        state.wordPos = int16(int256(maxWord) + 1);
        state.bitPos = 0;
        _validateComplete(poolId, state);
        return state;
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
        bytes32 tickWord = _readWord(address(manager), _tickInfoSlot(poolId, tick));
        assembly ("memory-safe") {
            liquidityGross := and(tickWord, 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF)
            liquidityNet := signextend(15, shr(128, tickWord))
        }
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
        if (!ERC165Checker.supportsInterface(provider, type(IHookStats).interfaceId)) {
            result.statsStatus =
                suppliedProvider == address(0) ? HookStatsStatus.NOT_SUPPORTED : HookStatsStatus.INVALID_PROVIDER;
            return;
        }

        (StaticCallStatus hookStatus, bytes32 hookWord,) =
            _boundedStaticcall(provider, HOOK_STATS_GAS_LIMIT, abi.encodeCall(IHookStats.hook, ()), 32);
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
            _boundedStaticcall(provider, HOOK_STATS_GAS_LIMIT, abi.encodeCall(IHookStats.getReserves, (key)), 64);
        if (reservesStatus != StaticCallStatus.SUCCESS) {
            result.statsStatus = _hookFailureStatus(reservesStatus);
            return;
        }

        (StaticCallStatus effectiveStatus, bytes32 effective0, bytes32 effective1) = _boundedStaticcall(
            provider, HOOK_STATS_GAS_LIMIT, abi.encodeCall(IHookStats.getEffectiveLiquidity, (key)), 64
        );
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

        result.statsStatus = suppliedProvider == address(0) ? HookStatsStatus.DIRECT : HookStatsStatus.EXTERNAL;
    }

    function _hookFailureStatus(StaticCallStatus status) private pure returns (HookStatsStatus) {
        return status == StaticCallStatus.FAILED ? HookStatsStatus.CALL_FAILED : HookStatsStatus.INVALID_RESPONSE;
    }

    function _readWord(address manager, bytes32 slot) private view returns (bytes32 value) {
        bytes memory input = abi.encodeCall(IExtsloadWord.extsload, (slot));
        (StaticCallStatus status, bytes32 word,) = _boundedStaticcall(manager, gasleft(), input, 32);
        if (status != StaticCallStatus.SUCCESS) revert ManagerReadFailed(manager, slot);
        return word;
    }

    function _readWords(address manager, bytes32[] memory slots) private view returns (bytes32[] memory values) {
        bytes memory input = abi.encodeCall(IExtsloadSparse.extsload, (slots));
        uint256 expectedSize = 64 + slots.length * 32;
        bytes memory output = new bytes(expectedSize);
        bool success;
        uint256 returnSize;
        assembly ("memory-safe") {
            success := staticcall(gas(), manager, add(input, 0x20), mload(input), add(output, 0x20), expectedSize)
            returnSize := returndatasize()
        }
        if (!success || returnSize != expectedSize) {
            revert ManagerBatchReadFailed(manager, slots[0], slots[slots.length - 1], slots.length);
        }

        uint256 offset;
        uint256 length;
        assembly ("memory-safe") {
            offset := mload(add(output, 0x20))
            length := mload(add(output, 0x40))
        }
        if (offset != 32 || length != slots.length) {
            revert ManagerBatchReadFailed(manager, slots[0], slots[slots.length - 1], slots.length);
        }

        values = new bytes32[](length);
        for (uint256 i; i < length; i++) {
            bytes32 word;
            assembly ("memory-safe") {
                word := mload(add(add(output, 0x60), mul(i, 0x20)))
            }
            values[i] = word;
        }
    }

    function _boundedStaticcall(address target, uint256 gasLimit, bytes memory input, uint256 expectedSize)
        private
        view
        returns (StaticCallStatus status, bytes32 word0, bytes32 word1)
    {
        bool success;
        uint256 returnSize;
        assembly ("memory-safe") {
            let output := mload(0x40)
            mstore(output, 0)
            mstore(add(output, 0x20), 0)
            success := staticcall(gasLimit, target, add(input, 0x20), mload(input), output, 0x40)
            returnSize := returndatasize()
            word0 := mload(output)
            word1 := mload(add(output, 0x20))
        }
        if (!success) return (StaticCallStatus.FAILED, bytes32(0), bytes32(0));
        if (returnSize != expectedSize) return (StaticCallStatus.INVALID_RESPONSE, bytes32(0), bytes32(0));
        return (StaticCallStatus.SUCCESS, word0, word1);
    }

    function _contextHash(IPoolManager manager, PoolId poolId) private pure returns (bytes32) {
        return keccak256(abi.encode(address(manager), PoolId.unwrap(poolId)));
    }

    function _poolStateSlot(PoolId poolId) private pure returns (bytes32) {
        return keccak256(abi.encodePacked(PoolId.unwrap(poolId), StateLibrary.POOLS_SLOT));
    }

    function _tickBitmapSlot(PoolId poolId, int16 wordPos) private pure returns (bytes32) {
        bytes32 mappingSlot = bytes32(uint256(_poolStateSlot(poolId)) + StateLibrary.TICK_BITMAP_OFFSET);
        return keccak256(abi.encodePacked(int256(wordPos), mappingSlot));
    }

    function _tickInfoSlot(PoolId poolId, int24 tick) private pure returns (bytes32) {
        bytes32 mappingSlot = bytes32(uint256(_poolStateSlot(poolId)) + StateLibrary.TICKS_OFFSET);
        return keccak256(abi.encodePacked(int256(tick), mappingSlot));
    }
}
