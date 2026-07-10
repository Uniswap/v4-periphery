// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IReservesLens} from "../src/interfaces/IReservesLens.sol";
import {ReservesLens} from "../src/lens/ReservesLens.sol";
import {Deploy} from "./shared/Deploy.sol";

contract ReservesLensTest is Test, Deployers {
    using StateLibrary for *;

    ReservesLens internal lens;

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();
        key = PoolKey(currency0, currency1, 3000, 60, IHooks(address(0)));
        manager.initialize(key, SQRT_PRICE_1_1);
        lens = new ReservesLens();
    }

    function test_emptyInitializedPool() public view {
        IReservesLens.PoolTVL memory result = lens.getPoolTVL(manager, key, address(0));
        assertEq(result.coreAmount0, 0);
        assertEq(result.coreAmount1, 0);
        assertEq(result.sqrtPriceX96, SQRT_PRICE_1_1);
        assertEq(result.tick, 0);
        assertEq(result.activeLiquidity, 0);
        assertEq(uint8(result.statsStatus), uint8(IReservesLens.HookStatsStatus.NO_HOOK));
    }

    function test_maximumTickSpacing() public {
        PoolKey memory maximumSpacing = PoolKey(currency0, currency1, 100, 32767, IHooks(address(0)));
        manager.initialize(maximumSpacing, SQRT_PRICE_1_1);
        IReservesLens.PoolTVL memory result = lens.getPoolTVL(manager, maximumSpacing, address(0));
        assertEq(result.coreAmount0, 0);
        assertEq(result.coreAmount1, 0);
    }

    function test_constructorFreeCreate2Deployment() public {
        bytes32 salt = keccak256("RESERVES_LENS_V1");
        bytes memory initcode = vm.getCode("ReservesLens.sol:ReservesLens");
        address expected = vm.computeCreate2Address(salt, keccak256(initcode), address(this));
        IReservesLens deployed = Deploy.reservesLens(salt);
        assertEq(address(deployed), expected);
        assertEq(keccak256(address(deployed).code), keccak256(address(lens).code));
    }

    function test_singleInRangePosition() public {
        uint128 liquidity = 10_000 ether;
        _modify(-120, 120, int256(uint256(liquidity)));

        IReservesLens.PoolTVL memory result = lens.getPoolTVL(manager, key, address(0));
        uint256 expected0 =
            SqrtPriceMath.getAmount0Delta(SQRT_PRICE_1_1, TickMath.getSqrtPriceAtTick(120), liquidity, false);
        uint256 expected1 =
            SqrtPriceMath.getAmount1Delta(TickMath.getSqrtPriceAtTick(-120), SQRT_PRICE_1_1, liquidity, false);
        assertEq(result.coreAmount0, expected0);
        assertEq(result.coreAmount1, expected1);
        assertEq(result.activeLiquidity, liquidity);
    }

    function test_positionsBelowAndAbovePrice() public {
        uint128 belowLiquidity = 7_000 ether;
        uint128 aboveLiquidity = 11_000 ether;
        _modify(-240, -120, int256(uint256(belowLiquidity)));
        _modify(120, 300, int256(uint256(aboveLiquidity)));

        IReservesLens.PoolTVL memory result = lens.getPoolTVL(manager, key, address(0));
        uint256 expected0 = SqrtPriceMath.getAmount0Delta(
            TickMath.getSqrtPriceAtTick(120), TickMath.getSqrtPriceAtTick(300), aboveLiquidity, false
        );
        uint256 expected1 = SqrtPriceMath.getAmount1Delta(
            TickMath.getSqrtPriceAtTick(-240), TickMath.getSqrtPriceAtTick(-120), belowLiquidity, false
        );
        assertEq(result.coreAmount0, expected0);
        assertEq(result.coreAmount1, expected1);
        assertEq(result.activeLiquidity, 0);
    }

    function test_removedPositionIsNotCounted() public {
        _modify(-120, 120, 10_000 ether);
        _modify(-120, 120, -10_000 ether);
        IReservesLens.PoolTVL memory result = lens.getPoolTVL(manager, key, address(0));
        assertEq(result.coreAmount0, 0);
        assertEq(result.coreAmount1, 0);
        assertEq(result.activeLiquidity, 0);
    }

    function test_zeroNetTickDoesNotSplitAggregateRounding() public {
        uint128 liquidity = 1_000_000;
        _modify(-120, 0, int256(uint256(liquidity)));
        _modify(0, 120, int256(uint256(liquidity)));

        IReservesLens.PoolTVL memory result = lens.getPoolTVL(manager, key, address(0));
        uint256 expected0 =
            SqrtPriceMath.getAmount0Delta(SQRT_PRICE_1_1, TickMath.getSqrtPriceAtTick(120), liquidity, false);
        uint256 expected1 =
            SqrtPriceMath.getAmount1Delta(TickMath.getSqrtPriceAtTick(-120), SQRT_PRICE_1_1, liquidity, false);
        assertEq(result.coreAmount0, expected0);
        assertEq(result.coreAmount1, expected1);
        assertEq(result.activeLiquidity, liquidity);
    }

    function test_afterSwapUsesStoredPriceAndTick() public {
        uint128 liquidity = 10_000 ether;
        _modify(-600, 600, int256(uint256(liquidity)));
        swap(key, true, -int256(100 ether), ZERO_BYTES);

        (uint160 sqrtPriceX96, int24 tick,,) = manager.getSlot0(key.toId());
        IReservesLens.PoolTVL memory result = lens.getPoolTVL(manager, key, address(0));
        uint256 expected0 =
            SqrtPriceMath.getAmount0Delta(sqrtPriceX96, TickMath.getSqrtPriceAtTick(600), liquidity, false);
        uint256 expected1 =
            SqrtPriceMath.getAmount1Delta(TickMath.getSqrtPriceAtTick(-600), sqrtPriceX96, liquidity, false);
        assertEq(result.sqrtPriceX96, sqrtPriceX96);
        assertEq(result.tick, tick);
        assertEq(result.coreAmount0, expected0);
        assertEq(result.coreAmount1, expected1);
    }

    function test_donationsAreExcluded() public {
        _modify(-120, 120, 10_000 ether);
        IReservesLens.PoolTVL memory beforeDonation = lens.getPoolTVL(manager, key, address(0));
        donateRouter.donate(key, 100 ether, 200 ether, ZERO_BYTES);
        IReservesLens.PoolTVL memory afterDonation = lens.getPoolTVL(manager, key, address(0));
        assertEq(afterDonation.coreAmount0, beforeDonation.coreAmount0);
        assertEq(afterDonation.coreAmount1, beforeDonation.coreAmount1);
    }

    function test_pagedEqualsSingleShot() public {
        _modify(-600, 600, 10_000 ether);
        _modify(-120, 180, 4_000 ether);
        _modify(0, 60, 2_000 ether);

        IReservesLens.PoolTVL memory expected = lens.getPoolTVL(manager, key, address(0));
        (IReservesLens.PoolTVL memory actual, uint256 pages) = _getPaged(key, 20);
        assertGt(pages, 1);
        _assertCoreEq(actual, expected);
    }

    function test_pagedMinimumBudgetMakesProgress() public {
        _modify(-120, 120, 10_000 ether);
        IReservesLens.PoolTVL memory expected = lens.getPoolTVL(manager, key, address(0));
        (IReservesLens.PoolTVL memory actual,) = _getPaged(key, 2);
        _assertCoreEq(actual, expected);
    }

    function test_batchEqualsIndividualCalls() public {
        _modify(-120, 120, 10_000 ether);
        PoolKey memory other = PoolKey(currency0, currency1, 500, 10, IHooks(address(0)));
        manager.initialize(other, SQRT_PRICE_1_1);

        PoolKey[] memory keys = new PoolKey[](2);
        keys[0] = key;
        keys[1] = other;
        address[] memory providers = new address[](2);
        IReservesLens.PoolTVL[] memory results = lens.getPoolTVLBatch(manager, keys, providers);

        assertEq(results.length, 2);
        _assertCoreEq(results[0], lens.getPoolTVL(manager, key, address(0)));
        _assertCoreEq(results[1], lens.getPoolTVL(manager, other, address(0)));
    }

    function test_getPopulatedTicksInWord() public {
        _modify(-120, 120, 10_000 ether);
        _modify(0, 60, 2_000 ether);

        IReservesLens.PopulatedTick[] memory ticks = lens.getPopulatedTicksInWord(manager, key, 0);
        assertEq(ticks.length, 3);
        assertEq(ticks[0].tick, 0);
        assertEq(ticks[0].liquidityNet, 2_000 ether);
        assertEq(ticks[0].liquidityGross, 2_000 ether);
        assertEq(ticks[1].tick, 60);
        assertEq(ticks[1].liquidityNet, -2_000 ether);
        assertEq(ticks[1].liquidityGross, 2_000 ether);
        assertEq(ticks[2].tick, 120);
        assertEq(ticks[2].liquidityNet, -10_000 ether);
        assertEq(ticks[2].liquidityGross, 10_000 ether);
    }

    function test_RevertWhen_BatchInputLengthsDiffer() public {
        PoolKey[] memory keys = new PoolKey[](1);
        keys[0] = key;
        address[] memory providers = new address[](0);
        vm.expectRevert(IReservesLens.InputLengthMismatch.selector);
        lens.getPoolTVLBatch(manager, keys, providers);
    }

    function test_RevertWhen_Uninitialized() public {
        PoolKey memory other = key;
        other.fee = 500;
        vm.expectRevert(abi.encodeWithSelector(IReservesLens.PoolNotInitialized.selector, other.toId()));
        lens.getPoolTVL(manager, other, address(0));
    }

    function test_RevertWhen_ManagerDoesNotImplementExtsload() public {
        vm.expectRevert();
        lens.getPoolTVL(IPoolManager(address(0xbeef)), key, address(0));
    }

    function test_RevertWhen_InvalidPageBudget() public {
        vm.expectRevert(abi.encodeWithSelector(IReservesLens.InvalidScanBudget.selector, uint32(1)));
        lens.getPoolTVLPaged(manager, key, address(0), bytes(""), 1);
        vm.expectRevert(abi.encodeWithSelector(IReservesLens.InvalidScanBudget.selector, uint32(4097)));
        lens.getPoolTVLPaged(manager, key, address(0), bytes(""), 4097);
    }

    function test_RevertWhen_CursorBlockChanges() public {
        (, bytes memory cursor, bool done) = lens.getPoolTVLPaged(manager, key, address(0), bytes(""), 2);
        assertFalse(done);
        uint256 previousBlock = block.number;
        vm.roll(previousBlock + 1);
        vm.expectRevert(
            abi.encodeWithSelector(IReservesLens.CursorBlockMismatch.selector, previousBlock, previousBlock + 1)
        );
        lens.getPoolTVLPaged(manager, key, address(0), cursor, 2);
    }

    function test_RevertWhen_CursorContextChanges() public {
        (, bytes memory cursor, bool done) = lens.getPoolTVLPaged(manager, key, address(0), bytes(""), 2);
        assertFalse(done);
        PoolKey memory other = key;
        other.fee = 500;
        vm.expectRevert(IReservesLens.CursorContextMismatch.selector);
        lens.getPoolTVLPaged(manager, other, address(0), cursor, 2);
    }

    function _modify(int24 lower, int24 upper, int256 liquidityDelta) private {
        modifyLiquidityRouter.modifyLiquidity(
            key, ModifyLiquidityParams(lower, upper, liquidityDelta, bytes32(0)), ZERO_BYTES
        );
    }

    function _getPaged(PoolKey memory poolKey, uint32 budget)
        private
        view
        returns (IReservesLens.PoolTVL memory result, uint256 pages)
    {
        bytes memory cursor;
        bool done;
        while (!done) {
            (result, cursor, done) = lens.getPoolTVLPaged(manager, poolKey, address(0), cursor, budget);
            pages++;
            assertLt(pages, 10_000);
        }
    }

    function _assertCoreEq(IReservesLens.PoolTVL memory actual, IReservesLens.PoolTVL memory expected) private pure {
        assertEq(actual.coreAmount0, expected.coreAmount0);
        assertEq(actual.coreAmount1, expected.coreAmount1);
        assertEq(actual.sqrtPriceX96, expected.sqrtPriceX96);
        assertEq(actual.tick, expected.tick);
        assertEq(actual.activeLiquidity, expected.activeLiquidity);
        assertEq(actual.blockNumber, expected.blockNumber);
    }
}
