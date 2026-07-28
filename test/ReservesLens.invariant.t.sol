// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {StdInvariant} from "forge-std/StdInvariant.sol";
import {Test} from "forge-std/Test.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IReservesLens} from "../src/interfaces/IReservesLens.sol";
import {ReservesLens} from "../src/lens/ReservesLens.sol";
import {ReservesReference} from "./shared/ReservesReference.sol";

contract ReservesLensInvariantTest is StdInvariant, Test, Deployers {
    using StateLibrary for *;

    int24[4] private lowers = [int24(-2400), int24(-600), int24(-120), int24(0)];
    int24[4] private uppers = [int24(-1200), int24(600), int24(120), int24(1200)];
    uint128[4] private liquidities;
    uint128 private constant BASE_LIQUIDITY = 10_000_000 ether;
    ReservesLens private lens;

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();
        key = PoolKey(currency0, currency1, 3000, 60, IHooks(address(0)));
        manager.initialize(key, SQRT_PRICE_1_1);
        lens = new ReservesLens();
        _modify(-6000, 6000, int256(uint256(BASE_LIQUIDITY)));

        bytes4[] memory selectors = new bytes4[](4);
        selectors[0] = this.addLiquidity.selector;
        selectors[1] = this.removeLiquidity.selector;
        selectors[2] = this.swapPool.selector;
        selectors[3] = this.donate.selector;
        targetSelector(FuzzSelector({addr: address(this), selectors: selectors}));
        targetContract(address(this));
    }

    function addLiquidity(uint8 rawIndex, uint96 rawAmount) external {
        uint256 index = rawIndex % liquidities.length;
        uint128 amount = uint128(bound(uint256(rawAmount), 1 ether, 1_000_000 ether));
        if (type(uint128).max - liquidities[index] < amount) return;
        _modify(lowers[index], uppers[index], int256(uint256(amount)));
        liquidities[index] += amount;
    }

    function removeLiquidity(uint8 rawIndex, uint96 rawAmount) external {
        uint256 index = rawIndex % liquidities.length;
        uint128 current = liquidities[index];
        if (current == 0) return;
        uint128 amount = current < 2 ether ? current : uint128(bound(uint256(rawAmount), 1 ether, current));
        _modify(lowers[index], uppers[index], -int256(uint256(amount)));
        liquidities[index] -= amount;
    }

    function swapPool(bool zeroForOne, uint96 rawAmount) external {
        uint256 amount = bound(uint256(rawAmount), 1, 1 ether);
        swap(key, zeroForOne, -int256(amount), ZERO_BYTES);
    }

    function donate(uint64 raw0, uint64 raw1) external {
        donateRouter.donate(key, uint256(raw0), uint256(raw1), ZERO_BYTES);
    }

    function invariant_matchesRecordedPositionAggregate() public view {
        ReservesReference.Position[] memory positions = new ReservesReference.Position[](5);
        positions[0] = ReservesReference.Position(-6000, 6000, BASE_LIQUIDITY);
        for (uint256 i; i < liquidities.length; i++) {
            positions[i + 1] = ReservesReference.Position(lowers[i], uppers[i], liquidities[i]);
        }

        (uint160 sqrtPriceX96, int24 currentTick,,) = manager.getSlot0(key.toId());
        (uint256 expected0, uint256 expected1, uint128 expectedActive) =
            ReservesReference.aggregate(sqrtPriceX96, currentTick, positions);
        IReservesLens.PoolTVL memory actual = lens.getPoolTVL(manager, key, address(0));
        assertEq(actual.coreAmount0, expected0);
        assertEq(actual.coreAmount1, expected1);
        assertEq(actual.activeLiquidity, expectedActive);
    }

    function _modify(int24 lower, int24 upper, int256 delta) private {
        modifyLiquidityNoChecks.modifyLiquidity(key, ModifyLiquidityParams(lower, upper, delta, bytes32(0)), ZERO_BYTES);
    }
}
