// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {Test} from "forge-std/Test.sol";
import {GetSender} from "./shared/GetSender.sol";
import {Hooks} from "@uniswap/v4-core/contracts/libraries/Hooks.sol";
import {GeomeanOracle} from "../contracts/hooks/examples/GeomeanOracle.sol";
import {GeomeanOracleImplementation} from "./shared/implementation/GeomeanOracleImplementation.sol";
import {PoolManager} from "@uniswap/v4-core/contracts/PoolManager.sol";
import {IPoolManager} from "@uniswap/v4-core/contracts/interfaces/IPoolManager.sol";
import {Deployers} from "@uniswap/v4-core/test/foundry-tests/utils/Deployers.sol";
import {TestERC20} from "@uniswap/v4-core/contracts/test/TestERC20.sol";
import {CurrencyLibrary, Currency} from "@uniswap/v4-core/contracts/libraries/CurrencyLibrary.sol";
import {PoolId} from "@uniswap/v4-core/contracts/libraries/PoolId.sol";
import {PoolModifyPositionTest} from "@uniswap/v4-core/contracts/test/PoolModifyPositionTest.sol";
import {TickMath} from "@uniswap/v4-core/contracts/libraries/TickMath.sol";
import {Oracle} from "../contracts/libraries/Oracle.sol";

contract TestGeomeanOracle is Test, Deployers {
    int24 constant MAX_TICK_SPACING = 32767;
    uint160 constant SQRT_RATIO_2_1 = 112045541949572279837463876454;

    TestERC20 token0;
    TestERC20 token1;
    PoolManager manager;
    GeomeanOracleImplementation geomeanOracle = GeomeanOracleImplementation(
        address(
            uint160(
                Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_MODIFY_POSITION_FLAG
                    | Hooks.BEFORE_SWAP_FLAG
            )
        )
    );
    IPoolManager.PoolKey key;
    bytes32 id;

    PoolModifyPositionTest modifyPositionRouter;

    function setUp() public {
        token0 = new TestERC20(2**128);
        token1 = new TestERC20(2**128);
        manager = new PoolManager(500000);

        vm.record();
        GeomeanOracleImplementation impl = new GeomeanOracleImplementation(manager, geomeanOracle);
        (, bytes32[] memory writes) = vm.accesses(address(impl));
        vm.etch(address(geomeanOracle), address(impl).code);
        // for each storage key that was written during the hook implementation, copy the value over
        unchecked {
            for (uint256 i = 0; i < writes.length; i++) {
                bytes32 slot = writes[i];
                vm.store(address(geomeanOracle), slot, vm.load(address(impl), slot));
            }
        }
        geomeanOracle.setTime(1);
        key = IPoolManager.PoolKey(
            Currency.wrap(address(token0)), Currency.wrap(address(token1)), 0, MAX_TICK_SPACING, geomeanOracle
        );
        id = PoolId.toId(key);

        modifyPositionRouter = new PoolModifyPositionTest(manager);

        token0.approve(address(geomeanOracle), type(uint256).max);
        token1.approve(address(geomeanOracle), type(uint256).max);
        token0.approve(address(modifyPositionRouter), type(uint256).max);
        token1.approve(address(modifyPositionRouter), type(uint256).max);
    }

    function testBeforeInitializeAllowsPoolCreation() public {
        manager.initialize(key, SQRT_RATIO_1_1);
    }

    function testBeforeInitializeRevertsIfFee() public {
        vm.expectRevert(GeomeanOracle.OnlyOneOraclePoolAllowed.selector);
        manager.initialize(
            IPoolManager.PoolKey(
                Currency.wrap(address(token0)), Currency.wrap(address(token1)), 1, MAX_TICK_SPACING, geomeanOracle
            ),
            SQRT_RATIO_1_1
        );
    }

    function testBeforeInitializeRevertsIfNotMaxTickSpacing() public {
        vm.expectRevert(GeomeanOracle.OnlyOneOraclePoolAllowed.selector);
        manager.initialize(
            IPoolManager.PoolKey(Currency.wrap(address(token0)), Currency.wrap(address(token1)), 0, 60, geomeanOracle),
            SQRT_RATIO_1_1
        );
    }

    function testAfterInitializeState() public {
        manager.initialize(key, SQRT_RATIO_2_1);
        GeomeanOracle.ObservationState memory observationState = geomeanOracle.getState(key);
        assertEq(observationState.index, 0);
        assertEq(observationState.cardinality, 1);
        assertEq(observationState.cardinalityNext, 1);
    }

    function testAfterInitializeObservation() public {
        manager.initialize(key, SQRT_RATIO_2_1);
        Oracle.Observation memory observation = geomeanOracle.getObservation(key, 0);
        assertTrue(observation.initialized);
        assertEq(observation.blockTimestamp, 1);
        assertEq(observation.tickCumulative, 0);
        assertEq(observation.secondsPerLiquidityCumulativeX128, 0);
    }

    function testAfterInitializeObserve0() public {
        manager.initialize(key, SQRT_RATIO_2_1);
        uint32[] memory secondsAgo = new uint32[](1);
        secondsAgo[0] = 0;
        (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s) =
            geomeanOracle.observe(key, secondsAgo);
        assertEq(tickCumulatives.length, 1);
        assertEq(secondsPerLiquidityCumulativeX128s.length, 1);
        assertEq(tickCumulatives[0], 0);
        assertEq(secondsPerLiquidityCumulativeX128s[0], 0);
    }

    function testBeforeModifyPositionNoObservations() public {
        manager.initialize(key, SQRT_RATIO_2_1);
        modifyPositionRouter.modifyPosition(
            key,
            IPoolManager.ModifyPositionParams(
                TickMath.minUsableTick(MAX_TICK_SPACING), TickMath.maxUsableTick(MAX_TICK_SPACING), 1000
            )
        );

        GeomeanOracle.ObservationState memory observationState = geomeanOracle.getState(key);
        assertEq(observationState.index, 0);
        assertEq(observationState.cardinality, 1);
        assertEq(observationState.cardinalityNext, 1);

        Oracle.Observation memory observation = geomeanOracle.getObservation(key, 0);
        assertTrue(observation.initialized);
        assertEq(observation.blockTimestamp, 1);
        assertEq(observation.tickCumulative, 0);
        assertEq(observation.secondsPerLiquidityCumulativeX128, 0);
    }

    function testBeforeModifyPositionObservation() public {
        manager.initialize(key, SQRT_RATIO_2_1);
        geomeanOracle.setTime(3); // advance 2 seconds
        modifyPositionRouter.modifyPosition(
            key,
            IPoolManager.ModifyPositionParams(
                TickMath.minUsableTick(MAX_TICK_SPACING), TickMath.maxUsableTick(MAX_TICK_SPACING), 1000
            )
        );

        GeomeanOracle.ObservationState memory observationState = geomeanOracle.getState(key);
        assertEq(observationState.index, 0);
        assertEq(observationState.cardinality, 1);
        assertEq(observationState.cardinalityNext, 1);

        Oracle.Observation memory observation = geomeanOracle.getObservation(key, 0);
        assertTrue(observation.initialized);
        assertEq(observation.blockTimestamp, 3);
        assertEq(observation.tickCumulative, 13862);
        assertEq(observation.secondsPerLiquidityCumulativeX128, 680564733841876926926749214863536422912);
    }

    function testBeforeModifyPositionObservationAndCardinality() public {
        manager.initialize(key, SQRT_RATIO_2_1);
        geomeanOracle.setTime(3); // advance 2 seconds
        geomeanOracle.increaseCardinalityNext(key, 2);
        GeomeanOracle.ObservationState memory observationState = geomeanOracle.getState(key);
        assertEq(observationState.index, 0);
        assertEq(observationState.cardinality, 1);
        assertEq(observationState.cardinalityNext, 2);

        modifyPositionRouter.modifyPosition(
            key,
            IPoolManager.ModifyPositionParams(
                TickMath.minUsableTick(MAX_TICK_SPACING), TickMath.maxUsableTick(MAX_TICK_SPACING), 1000
            )
        );

        // cardinality is updated
        observationState = geomeanOracle.getState(key);
        assertEq(observationState.index, 1);
        assertEq(observationState.cardinality, 2);
        assertEq(observationState.cardinalityNext, 2);

        // index 0 is untouched
        Oracle.Observation memory observation = geomeanOracle.getObservation(key, 0);
        assertTrue(observation.initialized);
        assertEq(observation.blockTimestamp, 1);
        assertEq(observation.tickCumulative, 0);
        assertEq(observation.secondsPerLiquidityCumulativeX128, 0);

        // index 1 is written
        observation = geomeanOracle.getObservation(key, 1);
        assertTrue(observation.initialized);
        assertEq(observation.blockTimestamp, 3);
        assertEq(observation.tickCumulative, 13862);
        assertEq(observation.secondsPerLiquidityCumulativeX128, 680564733841876926926749214863536422912);
    }
}
