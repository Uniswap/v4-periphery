// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {Test} from "forge-std/Test.sol";
import {GetSender} from "./shared/GetSender.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {GeomeanOracle} from "../contracts/hooks/examples/GeomeanOracle.sol";
import {GeomeanOracleImplementation} from "./shared/implementation/GeomeanOracleImplementation.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {TestERC20} from "@uniswap/v4-core/src/test/TestERC20.sol";
import {CurrencyLibrary, Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Oracle} from "../contracts/libraries/Oracle.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

contract TestGeomeanOracle is Test, Deployers {
    using PoolIdLibrary for PoolKey;

    int24 constant MAX_TICK_SPACING = 32767;

    TestERC20 token0;
    TestERC20 token1;
    GeomeanOracleImplementation geomeanOracle = GeomeanOracleImplementation(
        address(
            uint160(
                Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
                    | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG
            )
        )
    );
    PoolId id;

    function setUp() public {
        deployFreshManagerAndRouters();
        (currency0, currency1) = deployMintAndApprove2Currencies();

        token0 = TestERC20(Currency.unwrap(currency0));
        token1 = TestERC20(Currency.unwrap(currency1));

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
        key = PoolKey(currency0, currency1, 0, MAX_TICK_SPACING, geomeanOracle);
        id = key.toId();

        modifyLiquidityRouter = new PoolModifyLiquidityTest(manager);

        token0.approve(address(geomeanOracle), type(uint256).max);
        token1.approve(address(geomeanOracle), type(uint256).max);
        token0.approve(address(modifyLiquidityRouter), type(uint256).max);
        token1.approve(address(modifyLiquidityRouter), type(uint256).max);
    }

    function testBeforeInitializeAllowsPoolCreation() public {
        manager.initialize(key, SQRT_PRICE_1_1, ZERO_BYTES);
    }

    function testBeforeInitializeRevertsIfFee() public {
        vm.expectRevert(GeomeanOracle.OnlyOneOraclePoolAllowed.selector);
        manager.initialize(
            PoolKey(Currency.wrap(address(token0)), Currency.wrap(address(token1)), 1, MAX_TICK_SPACING, geomeanOracle),
            SQRT_PRICE_1_1,
            ZERO_BYTES
        );
    }

    function testBeforeInitializeRevertsIfNotMaxTickSpacing() public {
        vm.expectRevert(GeomeanOracle.OnlyOneOraclePoolAllowed.selector);
        manager.initialize(
            PoolKey(Currency.wrap(address(token0)), Currency.wrap(address(token1)), 0, 60, geomeanOracle),
            SQRT_PRICE_1_1,
            ZERO_BYTES
        );
    }

    function testAfterInitializeState() public {
        manager.initialize(key, SQRT_PRICE_2_1, ZERO_BYTES);
        GeomeanOracle.ObservationState memory observationState = geomeanOracle.getState(key);
        assertEq(observationState.index, 0);
        assertEq(observationState.cardinality, 1);
        assertEq(observationState.cardinalityNext, 1);
    }

    function testAfterInitializeObservation() public {
        manager.initialize(key, SQRT_PRICE_2_1, ZERO_BYTES);
        Oracle.Observation memory observation = geomeanOracle.getObservation(key, 0);
        assertTrue(observation.initialized);
        assertEq(observation.blockTimestamp, 1);
        assertEq(observation.tickCumulative, 0);
        assertEq(observation.secondsPerLiquidityCumulativeX128, 0);
    }

    function testAfterInitializeObserve0() public {
        manager.initialize(key, SQRT_PRICE_2_1, ZERO_BYTES);
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
        manager.initialize(key, SQRT_PRICE_2_1, ZERO_BYTES);
        modifyLiquidityRouter.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams(
                TickMath.minUsableTick(MAX_TICK_SPACING), TickMath.maxUsableTick(MAX_TICK_SPACING), 1000, 0
            ),
            ZERO_BYTES
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
        manager.initialize(key, SQRT_PRICE_2_1, ZERO_BYTES);
        geomeanOracle.setTime(3); // advance 2 seconds
        modifyLiquidityRouter.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams(
                TickMath.minUsableTick(MAX_TICK_SPACING), TickMath.maxUsableTick(MAX_TICK_SPACING), 1000, 0
            ),
            ZERO_BYTES
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
        manager.initialize(key, SQRT_PRICE_2_1, ZERO_BYTES);
        geomeanOracle.setTime(3); // advance 2 seconds
        geomeanOracle.increaseCardinalityNext(key, 2);
        GeomeanOracle.ObservationState memory observationState = geomeanOracle.getState(key);
        assertEq(observationState.index, 0);
        assertEq(observationState.cardinality, 1);
        assertEq(observationState.cardinalityNext, 2);

        modifyLiquidityRouter.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams(
                TickMath.minUsableTick(MAX_TICK_SPACING), TickMath.maxUsableTick(MAX_TICK_SPACING), 1000, 0
            ),
            ZERO_BYTES
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

    function testPermanentLiquidity() public {
        manager.initialize(key, SQRT_PRICE_2_1, ZERO_BYTES);
        geomeanOracle.setTime(3); // advance 2 seconds
        modifyLiquidityRouter.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams(
                TickMath.minUsableTick(MAX_TICK_SPACING), TickMath.maxUsableTick(MAX_TICK_SPACING), 1000, 0
            ),
            ZERO_BYTES
        );

        vm.expectRevert(GeomeanOracle.OraclePoolMustLockLiquidity.selector);
        modifyLiquidityRouter.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams(
                TickMath.minUsableTick(MAX_TICK_SPACING), TickMath.maxUsableTick(MAX_TICK_SPACING), -1000, 0
            ),
            ZERO_BYTES
        );
    }
}
