// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {BitMath} from "@uniswap/v4-core/src/libraries/BitMath.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IReservesLens} from "../src/interfaces/IReservesLens.sol";
import {IStateView} from "../src/interfaces/IStateView.sol";
import {ReservesLens} from "../src/lens/ReservesLens.sol";

/// @notice Pinned real-pool comparisons against the independently deployed StateView read path.
/// @dev Set BASE_RPC_URL and/or ROBINHOOD_RPC_URL to run.
contract ReservesLensForkTest is Test {
    using PoolIdLibrary for PoolKey;

    uint256 private constant BASE_BLOCK = 48_410_000;
    uint256 private constant ROBINHOOD_BLOCK = 6_448_000;
    IPoolManager private constant BASE_MANAGER = IPoolManager(0x498581fF718922c3f8e6A244956aF099B2652b2b);
    IStateView private constant BASE_STATE_VIEW = IStateView(0xA3c0c9b65baD0b08107Aa264b0f3dB444b867A71);
    IPoolManager private constant ROBINHOOD_MANAGER = IPoolManager(0x8366a39CC670B4001A1121B8F6A443A643e40951);
    IStateView private constant ROBINHOOD_STATE_VIEW = IStateView(0xF3334192D15450CdD385c8B70e03f9A6bD9E673b);

    struct ReferenceState {
        uint160 sqrtPriceX96;
        int24 currentTick;
        uint128 running;
        bool hasPrevious;
        int24 previous;
        uint256 amount0;
        uint256 amount1;
        uint128 reconstructedActive;
    }

    function test_base_realPoolsMatchStateViewReference() public {
        string memory rpc = vm.envOr("BASE_RPC_URL", string(""));
        vm.skip(bytes(rpc).length == 0);
        vm.createSelectFork(rpc, BASE_BLOCK);
        ReservesLens lens = new ReservesLens();

        _compare(lens, BASE_MANAGER, BASE_STATE_VIEW, _nativeUnhooked60());
        _compare(lens, BASE_MANAGER, BASE_STATE_VIEW, _usdcUnhooked200());
        _compare(lens, BASE_MANAGER, BASE_STATE_VIEW, _nativeHooked200());
        _compare(lens, BASE_MANAGER, BASE_STATE_VIEW, _dynamicHooked200());
    }

    function test_robinhoodChain_realPoolsMatchStateViewReference() public {
        string memory rpc = vm.envOr("ROBINHOOD_RPC_URL", string(""));
        vm.skip(bytes(rpc).length == 0);
        vm.createSelectFork(rpc, ROBINHOOD_BLOCK);
        ReservesLens lens = new ReservesLens();

        _compare(lens, ROBINHOOD_MANAGER, ROBINHOOD_STATE_VIEW, _robinhoodHooked200());
    }

    function _compare(ReservesLens lens, IPoolManager poolManager, IStateView stateView, PoolKey memory poolKey)
        private
    {
        PoolId poolId = poolKey.toId();
        (uint256 expected0, uint256 expected1, uint128 expectedActive) = _stateViewReference(stateView, poolKey);

        uint256 gasBefore = gasleft();
        IReservesLens.PoolTVL memory actual = lens.getPoolTVL(poolManager, poolKey, address(0));
        uint256 gasUsed = gasBefore - gasleft();

        assertEq(actual.coreAmount0, expected0, "amount0");
        assertEq(actual.coreAmount1, expected1, "amount1");
        assertEq(actual.activeLiquidity, expectedActive, "active liquidity");
        emit log_named_bytes32("pool id", PoolId.unwrap(poolId));
        emit log_named_uint("single-shot gas", gasUsed);
    }

    function _stateViewReference(IStateView stateView, PoolKey memory poolKey)
        private
        view
        returns (uint256 amount0, uint256 amount1, uint128 activeLiquidity)
    {
        PoolId poolId = poolKey.toId();
        ReferenceState memory state;
        (state.sqrtPriceX96, state.currentTick,,) = stateView.getSlot0(poolId);
        activeLiquidity = stateView.getLiquidity(poolId);
        int24 maxTick = TickMath.maxUsableTick(poolKey.tickSpacing);
        int24 minCompressed = TickMath.minUsableTick(poolKey.tickSpacing) / poolKey.tickSpacing;
        int16 wordPos = int16(minCompressed >> 8);
        int16 maxWord = int16((maxTick / poolKey.tickSpacing) >> 8);

        while (wordPos <= maxWord) {
            uint256 bitmap = stateView.getTickBitmap(poolId, wordPos);
            while (bitmap != 0) {
                uint8 bit = BitMath.leastSignificantBit(bitmap);
                int24 tick = int24((int256(wordPos) * 256 + int256(uint256(bit))) * int256(poolKey.tickSpacing));
                (, int128 net) = stateView.getTickLiquidity(poolId, tick);
                if (net != 0) _consumeTick(state, tick, net);
                bitmap &= bitmap - 1;
            }
            wordPos = int16(int256(wordPos) + 1);
        }

        assertEq(state.running, 0, "reference final liquidity");
        assertEq(state.reconstructedActive, activeLiquidity, "StateView active liquidity");
        return (state.amount0, state.amount1, activeLiquidity);
    }

    function _consumeTick(ReferenceState memory state, int24 tick, int128 net) private pure {
        if (state.hasPrevious) {
            if (state.currentTick >= state.previous && state.currentTick < tick) {
                state.reconstructedActive = state.running;
            }
            _addInterval(state, state.previous, tick);
        }
        state.running = uint128(uint256(int256(uint256(state.running)) + int256(net)));
        state.previous = tick;
        state.hasPrevious = true;
    }

    function _addInterval(ReferenceState memory state, int24 tickA, int24 tickB) private pure {
        if (state.running == 0) return;
        uint160 sqrtA = TickMath.getSqrtPriceAtTick(tickA);
        uint160 sqrtB = TickMath.getSqrtPriceAtTick(tickB);
        if (state.currentTick < tickA) {
            state.amount0 += SqrtPriceMath.getAmount0Delta(sqrtA, sqrtB, state.running, false);
        } else if (state.currentTick < tickB) {
            state.amount0 += SqrtPriceMath.getAmount0Delta(state.sqrtPriceX96, sqrtB, state.running, false);
            state.amount1 += SqrtPriceMath.getAmount1Delta(sqrtA, state.sqrtPriceX96, state.running, false);
        } else {
            state.amount1 += SqrtPriceMath.getAmount1Delta(sqrtA, sqrtB, state.running, false);
        }
    }

    function _nativeUnhooked60() private pure returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(bytes20(hex"ae2f44ab8e3d21dbbd4d13e287fa167139df7cdc"))),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });
    }

    function _usdcUnhooked200() private pure returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(address(bytes20(hex"833589fcd6edb6e08f4c7c32d4f71b54bda02913"))),
            currency1: Currency.wrap(address(bytes20(hex"b200000000000000000000cc6ef45b2edadc7b3f"))),
            fee: 0x0d5ffc,
            tickSpacing: 200,
            hooks: IHooks(address(0))
        });
    }

    function _nativeHooked200() private pure returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(bytes20(hex"b20000000000000000000028f8cbbdda0469f701"))),
            fee: 0,
            tickSpacing: 200,
            hooks: IHooks(address(bytes20(hex"a068cf4c52abdd3479145c4b3cbd8e3d71542a44")))
        });
    }

    function _dynamicHooked200() private pure returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(address(bytes20(hex"387c91d4d7b3a0bb72b743615324b2e0d8512271"))),
            currency1: Currency.wrap(address(bytes20(hex"ce74d58e78c43f00b8159e1b9287736f8f6b06fc"))),
            fee: 0x800000,
            tickSpacing: 200,
            hooks: IHooks(address(bytes20(hex"0469a4bd3724dc86c9542f4694c976da13c450c0")))
        });
    }

    function _robinhoodHooked200() private pure returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(address(bytes20(hex"0bd7d308f8e1639fab988df18a8011f41eacad73"))),
            currency1: Currency.wrap(address(bytes20(hex"894fac757250f8e02180e1856957274d84ac4ba3"))),
            fee: 0x800000,
            tickSpacing: 200,
            hooks: IHooks(address(bytes20(hex"4e3468951d49f2eea976ed0d6e75ffcb44a9a544")))
        });
    }
}
