// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IReservesLens} from "../src/interfaces/IReservesLens.sol";
import {ReservesLens} from "../src/lens/ReservesLens.sol";
import {ReservesReference} from "./shared/ReservesReference.sol";

contract ReservesLensFuzzTest is Test, Deployers {
    using StateLibrary for *;

    ReservesLens internal lens;

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();
        key = PoolKey(currency0, currency1, 3000, 60, IHooks(address(0)));
        manager.initialize(key, SQRT_PRICE_1_1);
        lens = new ReservesLens();
    }

    function test_fuzz_matchesIndependentAggregate(
        int16[6] memory rawTicks,
        uint96[3] memory rawLiquidity,
        bool performSwap,
        bool zeroForOne,
        uint96 rawSwapAmount,
        uint32 rawBudget
    ) public {
        ReservesReference.Position[] memory positions = new ReservesReference.Position[](4);
        positions[0] = ReservesReference.Position(-6000, 6000, 10_000_000 ether);
        _add(positions[0]);

        for (uint256 i; i < 3; i++) {
            int24 a = int24(int256(bound(int256(rawTicks[i * 2]), -90, 89))) * 60;
            int24 b = int24(int256(bound(int256(rawTicks[i * 2 + 1]), -90, 89))) * 60;
            if (a == b) b += b == 89 * 60 ? int24(-60) : int24(60);
            if (a > b) (a, b) = (b, a);
            uint128 liquidity = uint128(bound(uint256(rawLiquidity[i]), 1, 1_000_000 ether));
            positions[i + 1] = ReservesReference.Position(a, b, liquidity);
            _add(positions[i + 1]);
        }

        if (performSwap) {
            uint256 swapAmount = bound(uint256(rawSwapAmount), 1, 1 ether);
            swap(key, zeroForOne, -int256(swapAmount), ZERO_BYTES);
        }

        (uint160 sqrtPriceX96, int24 currentTick,,) = manager.getSlot0(key.toId());
        (uint256 expected0, uint256 expected1, uint128 expectedActive) =
            ReservesReference.aggregate(sqrtPriceX96, currentTick, positions);
        IReservesLens.PoolTVL memory single = lens.getPoolTVL(manager, key, address(0));
        assertEq(single.coreAmount0, expected0);
        assertEq(single.coreAmount1, expected1);
        assertEq(single.activeLiquidity, expectedActive);

        uint32 budget = uint32(bound(uint256(rawBudget), 2, 64));
        IReservesLens.PoolTVL memory paged = _getPaged(budget);
        assertEq(paged.coreAmount0, single.coreAmount0);
        assertEq(paged.coreAmount1, single.coreAmount1);
        assertEq(paged.activeLiquidity, single.activeLiquidity);
    }

    function _add(ReservesReference.Position memory position) private {
        modifyLiquidityRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams(position.lower, position.upper, int256(uint256(position.liquidity)), bytes32(0)),
            ZERO_BYTES
        );
    }

    function _getPaged(uint32 budget) private view returns (IReservesLens.PoolTVL memory result) {
        bytes memory cursor;
        bool done;
        uint256 pages;
        while (!done) {
            (result, cursor, done) = lens.getPoolTVLPaged(manager, key, address(0), cursor, budget);
            assertLt(++pages, 10_000);
        }
    }
}
