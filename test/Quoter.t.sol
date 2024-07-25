//SPDX-License-Identifier: UNLICENSED

pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {PathKey} from "../src/libraries/PathKey.sol";
import {IQuoter} from "../src/interfaces/IQuoter.sol";
import {Quoter} from "../src/lens/Quoter.sol";

// v4-core
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";

// solmate
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

contract QuoterTest is Test, Deployers {
    using SafeCast for *;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    // Min tick for full range with tick spacing of 60
    int24 internal constant MIN_TICK = -887220;
    // Max tick for full range with tick spacing of 60
    int24 internal constant MAX_TICK = -MIN_TICK;

    uint160 internal constant SQRT_PRICE_100_102 = 78447570448055484695608110440;
    uint160 internal constant SQRT_PRICE_102_100 = 80016521857016594389520272648;

    uint256 internal constant CONTROLLER_GAS_LIMIT = 500000;

    Quoter quoter;

    PoolModifyLiquidityTest positionManager;

    MockERC20 token0;
    MockERC20 token1;
    MockERC20 token2;

    PoolKey key01;
    PoolKey key02;
    PoolKey key12;

    MockERC20[] tokenPath;

    function setUp() public {
        deployFreshManagerAndRouters();
        quoter = new Quoter(IPoolManager(manager));
        positionManager = new PoolModifyLiquidityTest(manager);

        // salts are chosen so that address(token0) < address(token1) && address(token1) < address(token2)
        token0 = new MockERC20("Test0", "0", 18);
        vm.etch(address(0x1111), address(token0).code);
        token0 = MockERC20(address(0x1111));
        token0.mint(address(this), 2 ** 128);

        vm.etch(address(0x2222), address(token0).code);
        token1 = MockERC20(address(0x2222));
        token1.mint(address(this), 2 ** 128);

        vm.etch(address(0x3333), address(token0).code);
        token2 = MockERC20(address(0x3333));
        token2.mint(address(this), 2 ** 128);

        key01 = createPoolKey(token0, token1, address(0));
        key02 = createPoolKey(token0, token2, address(0));
        key12 = createPoolKey(token1, token2, address(0));
        setupPool(key01);
        setupPool(key12);
        setupPoolMultiplePositions(key02);
    }

    function testQuoter_quoteExactInputSingle_ZeroForOne_MultiplePositions() public {
        uint256 amountIn = 10000;
        uint256 expectedAmountOut = 9871;
        uint160 expectedSqrtPriceX96After = 78461846509168490764501028180;

        (int128[] memory deltaAmounts, uint160 sqrtPriceX96After, uint32 initializedTicksLoaded) = quoter
            .quoteExactInputSingle(
            IQuoter.QuoteExactSingleParams({
                poolKey: key02,
                zeroForOne: true,
                recipient: address(this),
                exactAmount: uint128(amountIn),
                sqrtPriceLimitX96: 0,
                hookData: ZERO_BYTES
            })
        );

        assertEq(uint128(-deltaAmounts[1]), expectedAmountOut);
        assertEq(sqrtPriceX96After, expectedSqrtPriceX96After);
        assertEq(initializedTicksLoaded, 2);
    }

    function testQuoter_quoteExactInputSingle_OneForZero_MultiplePositions() public {
        uint256 amountIn = 10000;
        uint256 expectedAmountOut = 9871;
        uint160 expectedSqrtPriceX96After = 80001962924147897865541384515;

        (int128[] memory deltaAmounts, uint160 sqrtPriceX96After, uint32 initializedTicksLoaded) = quoter
            .quoteExactInputSingle(
            IQuoter.QuoteExactSingleParams({
                poolKey: key02,
                zeroForOne: false,
                recipient: address(this),
                exactAmount: uint128(amountIn),
                sqrtPriceLimitX96: 0,
                hookData: ZERO_BYTES
            })
        );

        assertEq(uint128(-deltaAmounts[0]), expectedAmountOut);
        assertEq(sqrtPriceX96After, expectedSqrtPriceX96After);
        assertEq(initializedTicksLoaded, 2);
    }

    // nested self-call into unlockCallback reverts
    function testQuoter_callUnlockCallback_reverts() public {
        vm.expectRevert(IQuoter.LockFailure.selector);
        vm.prank(address(manager));
        quoter.unlockCallback(abi.encodeWithSelector(quoter.unlockCallback.selector, address(this), "0x"));
    }

    function testQuoter_quoteExactInput_0to2_2TicksLoaded() public {
        tokenPath.push(token0);
        tokenPath.push(token2);
        IQuoter.QuoteExactParams memory params = getExactInputParams(tokenPath, 10000);

        (
            int128[] memory deltaAmounts,
            uint160[] memory sqrtPriceX96AfterList,
            uint32[] memory initializedTicksLoadedList
        ) = quoter.quoteExactInput(params);

        assertEq(uint128(-deltaAmounts[1]), 9871);
        assertEq(sqrtPriceX96AfterList[0], 78461846509168490764501028180);
        assertEq(initializedTicksLoadedList[0], 2);
    }

    function testQuoter_quoteExactInput_0to2_2TicksLoaded_initialiedAfter() public {
        tokenPath.push(token0);
        tokenPath.push(token2);

        // The swap amount is set such that the active tick after the swap is -120.
        // -120 is an initialized tick for this pool. We check that we don't count it.
        IQuoter.QuoteExactParams memory params = getExactInputParams(tokenPath, 6200);

        (
            int128[] memory deltaAmounts,
            uint160[] memory sqrtPriceX96AfterList,
            uint32[] memory initializedTicksLoadedList
        ) = quoter.quoteExactInput(params);

        assertEq(uint128(-deltaAmounts[1]), 6143);
        assertEq(sqrtPriceX96AfterList[0], 78757224507315167622282810783);
        assertEq(initializedTicksLoadedList[0], 1);
    }

    function testQuoter_quoteExactInput_0to2_1TickLoaded() public {
        tokenPath.push(token0);
        tokenPath.push(token2);

        // The swap amount is set such that the active tick after the swap is -60.
        // -60 is an initialized tick for this pool. We check that we don't count it.
        IQuoter.QuoteExactParams memory params = getExactInputParams(tokenPath, 4000);

        (
            int128[] memory deltaAmounts,
            uint160[] memory sqrtPriceX96AfterList,
            uint32[] memory initializedTicksLoadedList
        ) = quoter.quoteExactInput(params);

        assertEq(uint128(-deltaAmounts[1]), 3971);
        assertEq(sqrtPriceX96AfterList[0], 78926452400586371254602774705);
        assertEq(initializedTicksLoadedList[0], 1);
    }

    function testQuoter_quoteExactInput_0to2_0TickLoaded_startingNotInitialized() public {
        tokenPath.push(token0);
        tokenPath.push(token2);
        IQuoter.QuoteExactParams memory params = getExactInputParams(tokenPath, 10);

        (
            int128[] memory deltaAmounts,
            uint160[] memory sqrtPriceX96AfterList,
            uint32[] memory initializedTicksLoadedList
        ) = quoter.quoteExactInput(params);

        assertEq(uint128(-deltaAmounts[1]), 8);
        assertEq(sqrtPriceX96AfterList[0], 79227483487511329217250071027);
        assertEq(initializedTicksLoadedList[0], 0);
    }

    function testQuoter_quoteExactInput_0to2_0TickLoaded_startingInitialized() public {
        setupPoolWithZeroTickInitialized(key02);
        tokenPath.push(token0);
        tokenPath.push(token2);
        IQuoter.QuoteExactParams memory params = getExactInputParams(tokenPath, 10);

        (
            int128[] memory deltaAmounts,
            uint160[] memory sqrtPriceX96AfterList,
            uint32[] memory initializedTicksLoadedList
        ) = quoter.quoteExactInput(params);

        assertEq(uint128(-deltaAmounts[1]), 8);
        assertEq(sqrtPriceX96AfterList[0], 79227817515327498931091950511);
        assertEq(initializedTicksLoadedList[0], 1);
    }

    function testQuoter_quoteExactInput_2to0_2TicksLoaded() public {
        tokenPath.push(token2);
        tokenPath.push(token0);
        IQuoter.QuoteExactParams memory params = getExactInputParams(tokenPath, 10000);

        (
            int128[] memory deltaAmounts,
            uint160[] memory sqrtPriceX96AfterList,
            uint32[] memory initializedTicksLoadedList
        ) = quoter.quoteExactInput(params);

        assertEq(-deltaAmounts[1], 9871);
        assertEq(sqrtPriceX96AfterList[0], 80001962924147897865541384515);
        assertEq(initializedTicksLoadedList[0], 2);
    }

    function testQuoter_quoteExactInput_2to0_2TicksLoaded_initialiedAfter() public {
        tokenPath.push(token2);
        tokenPath.push(token0);

        // The swap amount is set such that the active tick after the swap is 120.
        // 120 is an initialized tick for this pool. We check that we don't count it.
        IQuoter.QuoteExactParams memory params = getExactInputParams(tokenPath, 6250);

        (
            int128[] memory deltaAmounts,
            uint160[] memory sqrtPriceX96AfterList,
            uint32[] memory initializedTicksLoadedList
        ) = quoter.quoteExactInput(params);

        assertEq(-deltaAmounts[1], 6190);
        assertEq(sqrtPriceX96AfterList[0], 79705728824507063507279123685);
        assertEq(initializedTicksLoadedList[0], 2);
    }

    function testQuoter_quoteExactInput_2to0_0TickLoaded_startingInitialized() public {
        setupPoolWithZeroTickInitialized(key02);
        tokenPath.push(token2);
        tokenPath.push(token0);
        IQuoter.QuoteExactParams memory params = getExactInputParams(tokenPath, 200);

        // Tick 0 initialized. Tick after = 1
        (
            int128[] memory deltaAmounts,
            uint160[] memory sqrtPriceX96AfterList,
            uint32[] memory initializedTicksLoadedList
        ) = quoter.quoteExactInput(params);

        assertEq(-deltaAmounts[1], 198);
        assertEq(sqrtPriceX96AfterList[0], 79235729830182478001034429156);
        assertEq(initializedTicksLoadedList[0], 0);
    }

    // 2->0 starting not initialized
    function testQuoter_quoteExactInput_2to0_0TickLoaded_startingNotInitialized() public {
        tokenPath.push(token2);
        tokenPath.push(token0);
        IQuoter.QuoteExactParams memory params = getExactInputParams(tokenPath, 103);

        (
            int128[] memory deltaAmounts,
            uint160[] memory sqrtPriceX96AfterList,
            uint32[] memory initializedTicksLoadedList
        ) = quoter.quoteExactInput(params);

        assertEq(-deltaAmounts[1], 101);
        assertEq(sqrtPriceX96AfterList[0], 79235858216754624215638319723);
        assertEq(initializedTicksLoadedList[0], 0);
    }

    function testQuoter_quoteExactInput_2to1() public {
        tokenPath.push(token2);
        tokenPath.push(token1);
        IQuoter.QuoteExactParams memory params = getExactInputParams(tokenPath, 10000);

        (
            int128[] memory deltaAmounts,
            uint160[] memory sqrtPriceX96AfterList,
            uint32[] memory initializedTicksLoadedList
        ) = quoter.quoteExactInput(params);
        assertEq(-deltaAmounts[1], 9871);
        assertEq(sqrtPriceX96AfterList[0], 80018067294531553039351583520);
        assertEq(initializedTicksLoadedList[0], 0);
    }

    function testQuoter_quoteExactInput_0to2to1() public {
        tokenPath.push(token0);
        tokenPath.push(token2);
        tokenPath.push(token1);
        IQuoter.QuoteExactParams memory params = getExactInputParams(tokenPath, 10000);

        (
            int128[] memory deltaAmounts,
            uint160[] memory sqrtPriceX96AfterList,
            uint32[] memory initializedTicksLoadedList
        ) = quoter.quoteExactInput(params);

        assertEq(-deltaAmounts[2], 9745);
        assertEq(sqrtPriceX96AfterList[0], 78461846509168490764501028180);
        assertEq(sqrtPriceX96AfterList[1], 80007846861567212939802016351);
        assertEq(initializedTicksLoadedList[0], 2);
        assertEq(initializedTicksLoadedList[1], 0);
    }

    function testQuoter_quoteExactOutputSingle_0to1() public {
        (int128[] memory deltaAmounts, uint160 sqrtPriceX96After, uint32 initializedTicksLoaded) = quoter
            .quoteExactOutputSingle(
            IQuoter.QuoteExactSingleParams({
                poolKey: key01,
                zeroForOne: true,
                recipient: address(this),
                exactAmount: type(uint128).max,
                sqrtPriceLimitX96: SQRT_PRICE_100_102,
                hookData: ZERO_BYTES
            })
        );

        assertEq(deltaAmounts[0], 9981);
        assertEq(sqrtPriceX96After, SQRT_PRICE_100_102);
        assertEq(initializedTicksLoaded, 0);
    }

    function testQuoter_quoteExactOutputSingle_1to0() public {
        (int128[] memory deltaAmounts, uint160 sqrtPriceX96After, uint32 initializedTicksLoaded) = quoter
            .quoteExactOutputSingle(
            IQuoter.QuoteExactSingleParams({
                poolKey: key01,
                zeroForOne: false,
                recipient: address(this),
                exactAmount: type(uint128).max,
                sqrtPriceLimitX96: SQRT_PRICE_102_100,
                hookData: ZERO_BYTES
            })
        );

        assertEq(deltaAmounts[1], 9981);
        assertEq(sqrtPriceX96After, SQRT_PRICE_102_100);
        assertEq(initializedTicksLoaded, 0);
    }

    function testQuoter_quoteExactOutput_0to2_2TicksLoaded() public {
        tokenPath.push(token0);
        tokenPath.push(token2);
        IQuoter.QuoteExactParams memory params = getExactOutputParams(tokenPath, 15000);

        (
            int128[] memory deltaAmounts,
            uint160[] memory sqrtPriceX96AfterList,
            uint32[] memory initializedTicksLoadedList
        ) = quoter.quoteExactOutput(params);

        assertEq(deltaAmounts[0], 15273);
        assertEq(sqrtPriceX96AfterList[0], 78055527257643669242286029831);
        assertEq(initializedTicksLoadedList[0], 2);
    }

    function testQuoter_quoteExactOutput_0to2_1TickLoaded_initialiedAfter() public {
        tokenPath.push(token0);
        tokenPath.push(token2);

        IQuoter.QuoteExactParams memory params = getExactOutputParams(tokenPath, 6143);

        (
            int128[] memory deltaAmounts,
            uint160[] memory sqrtPriceX96AfterList,
            uint32[] memory initializedTicksLoadedList
        ) = quoter.quoteExactOutput(params);

        assertEq(deltaAmounts[0], 6200);
        assertEq(sqrtPriceX96AfterList[0], 78757225449310403327341205211);
        assertEq(initializedTicksLoadedList[0], 1);
    }

    function testQuoter_quoteExactOutput_0to2_1TickLoaded() public {
        tokenPath.push(token0);
        tokenPath.push(token2);

        IQuoter.QuoteExactParams memory params = getExactOutputParams(tokenPath, 4000);

        (
            int128[] memory deltaAmounts,
            uint160[] memory sqrtPriceX96AfterList,
            uint32[] memory initializedTicksLoadedList
        ) = quoter.quoteExactOutput(params);

        assertEq(deltaAmounts[0], 4029);
        assertEq(sqrtPriceX96AfterList[0], 78924219757724709840818372098);
        assertEq(initializedTicksLoadedList[0], 1);
    }

    function testQuoter_quoteExactOutput_0to2_0TickLoaded_startingInitialized() public {
        setupPoolWithZeroTickInitialized(key02);
        tokenPath.push(token0);
        tokenPath.push(token2);

        IQuoter.QuoteExactParams memory params = getExactOutputParams(tokenPath, 100);

        // Tick 0 initialized. Tick after = 1
        (
            int128[] memory deltaAmounts,
            uint160[] memory sqrtPriceX96AfterList,
            uint32[] memory initializedTicksLoadedList
        ) = quoter.quoteExactOutput(params);

        assertEq(deltaAmounts[0], 102);
        assertEq(sqrtPriceX96AfterList[0], 79224329176051641448521403903);
        assertEq(initializedTicksLoadedList[0], 1);
    }

    function testQuoter_quoteExactOutput_0to2_0TickLoaded_startingNotInitialized() public {
        tokenPath.push(token0);
        tokenPath.push(token2);

        IQuoter.QuoteExactParams memory params = getExactOutputParams(tokenPath, 10);

        (
            int128[] memory deltaAmounts,
            uint160[] memory sqrtPriceX96AfterList,
            uint32[] memory initializedTicksLoadedList
        ) = quoter.quoteExactOutput(params);

        assertEq(deltaAmounts[0], 12);
        assertEq(sqrtPriceX96AfterList[0], 79227408033628034983534698435);
        assertEq(initializedTicksLoadedList[0], 0);
    }

    function testQuoter_quoteExactOutput_2to0_2TicksLoaded() public {
        tokenPath.push(token2);
        tokenPath.push(token0);
        IQuoter.QuoteExactParams memory params = getExactOutputParams(tokenPath, 15000);

        (
            int128[] memory deltaAmounts,
            uint160[] memory sqrtPriceX96AfterList,
            uint32[] memory initializedTicksLoadedList
        ) = quoter.quoteExactOutput(params);

        assertEq(deltaAmounts[0], 15273);
        assertEq(sqrtPriceX96AfterList[0], 80418414376567919517220409857);
        assertEq(initializedTicksLoadedList.length, 1);
        assertEq(initializedTicksLoadedList[0], 2);
    }

    function testQuoter_quoteExactOutput_2to0_2TicksLoaded_initialiedAfter() public {
        tokenPath.push(token2);
        tokenPath.push(token0);

        IQuoter.QuoteExactParams memory params = getExactOutputParams(tokenPath, 6223);

        (
            int128[] memory deltaAmounts,
            uint160[] memory sqrtPriceX96AfterList,
            uint32[] memory initializedTicksLoadedList
        ) = quoter.quoteExactOutput(params);

        assertEq(deltaAmounts[0], 6283);
        assertEq(sqrtPriceX96AfterList[0], 79708304437530892332449657932);
        assertEq(initializedTicksLoadedList.length, 1);
        assertEq(initializedTicksLoadedList[0], 2);
    }

    function testQuoter_quoteExactOutput_2to0_1TickLoaded() public {
        tokenPath.push(token2);
        tokenPath.push(token0);

        IQuoter.QuoteExactParams memory params = getExactOutputParams(tokenPath, 6000);
        (
            int128[] memory deltaAmounts,
            uint160[] memory sqrtPriceX96AfterList,
            uint32[] memory initializedTicksLoadedList
        ) = quoter.quoteExactOutput(params);

        assertEq(deltaAmounts[0], 6055);
        assertEq(sqrtPriceX96AfterList[0], 79690640184021170956740081887);
        assertEq(initializedTicksLoadedList.length, 1);
        assertEq(initializedTicksLoadedList[0], 1);
    }

    function testQuoter_quoteExactOutput_2to1() public {
        tokenPath.push(token2);
        tokenPath.push(token1);

        IQuoter.QuoteExactParams memory params = getExactOutputParams(tokenPath, 9871);

        (
            int128[] memory deltaAmounts,
            uint160[] memory sqrtPriceX96AfterList,
            uint32[] memory initializedTicksLoadedList
        ) = quoter.quoteExactOutput(params);

        assertEq(deltaAmounts[0], 10000);
        assertEq(sqrtPriceX96AfterList[0], 80018020393569259756601362385);
        assertEq(initializedTicksLoadedList.length, 1);
        assertEq(initializedTicksLoadedList[0], 0);
    }

    function testQuoter_quoteExactOutput_0to2to1() public {
        tokenPath.push(token0);
        tokenPath.push(token2);
        tokenPath.push(token1);

        IQuoter.QuoteExactParams memory params = getExactOutputParams(tokenPath, 9745);

        (
            int128[] memory deltaAmounts,
            uint160[] memory sqrtPriceX96AfterList,
            uint32[] memory initializedTicksLoadedList
        ) = quoter.quoteExactOutput(params);

        assertEq(deltaAmounts[0], 10000);
        assertEq(deltaAmounts[1], 0);
        assertEq(deltaAmounts[2], -9745);
        assertEq(sqrtPriceX96AfterList[0], 78461888503179331029803316753);
        assertEq(sqrtPriceX96AfterList[1], 80007838904387594703933785072);
        assertEq(initializedTicksLoadedList.length, 2);
        assertEq(initializedTicksLoadedList[0], 2);
        assertEq(initializedTicksLoadedList[1], 0);
    }

    function createPoolKey(MockERC20 tokenA, MockERC20 tokenB, address hookAddr)
        internal
        pure
        returns (PoolKey memory)
    {
        if (address(tokenA) > address(tokenB)) (tokenA, tokenB) = (tokenB, tokenA);
        return PoolKey(Currency.wrap(address(tokenA)), Currency.wrap(address(tokenB)), 3000, 60, IHooks(hookAddr));
    }

    function setupPool(PoolKey memory poolKey) internal {
        manager.initialize(poolKey, SQRT_PRICE_1_1, ZERO_BYTES);
        MockERC20(Currency.unwrap(poolKey.currency0)).approve(address(positionManager), type(uint256).max);
        MockERC20(Currency.unwrap(poolKey.currency1)).approve(address(positionManager), type(uint256).max);
        positionManager.modifyLiquidity(
            poolKey,
            IPoolManager.ModifyLiquidityParams(
                MIN_TICK,
                MAX_TICK,
                calculateLiquidityFromAmounts(SQRT_PRICE_1_1, MIN_TICK, MAX_TICK, 1000000, 1000000).toInt256(),
                0
            ),
            ZERO_BYTES
        );
    }

    function setupPoolMultiplePositions(PoolKey memory poolKey) internal {
        manager.initialize(poolKey, SQRT_PRICE_1_1, ZERO_BYTES);
        MockERC20(Currency.unwrap(poolKey.currency0)).approve(address(positionManager), type(uint256).max);
        MockERC20(Currency.unwrap(poolKey.currency1)).approve(address(positionManager), type(uint256).max);
        positionManager.modifyLiquidity(
            poolKey,
            IPoolManager.ModifyLiquidityParams(
                MIN_TICK,
                MAX_TICK,
                calculateLiquidityFromAmounts(SQRT_PRICE_1_1, MIN_TICK, MAX_TICK, 1000000, 1000000).toInt256(),
                0
            ),
            ZERO_BYTES
        );
        positionManager.modifyLiquidity(
            poolKey,
            IPoolManager.ModifyLiquidityParams(
                -60, 60, calculateLiquidityFromAmounts(SQRT_PRICE_1_1, -60, 60, 100, 100).toInt256(), 0
            ),
            ZERO_BYTES
        );
        positionManager.modifyLiquidity(
            poolKey,
            IPoolManager.ModifyLiquidityParams(
                -120, 120, calculateLiquidityFromAmounts(SQRT_PRICE_1_1, -120, 120, 100, 100).toInt256(), 0
            ),
            ZERO_BYTES
        );
    }

    function setupPoolWithZeroTickInitialized(PoolKey memory poolKey) internal {
        PoolId poolId = poolKey.toId();
        (uint160 sqrtPriceX96,,,) = manager.getSlot0(poolId);
        if (sqrtPriceX96 == 0) {
            manager.initialize(poolKey, SQRT_PRICE_1_1, ZERO_BYTES);
        }

        MockERC20(Currency.unwrap(poolKey.currency0)).approve(address(positionManager), type(uint256).max);
        MockERC20(Currency.unwrap(poolKey.currency1)).approve(address(positionManager), type(uint256).max);
        positionManager.modifyLiquidity(
            poolKey,
            IPoolManager.ModifyLiquidityParams(
                MIN_TICK,
                MAX_TICK,
                calculateLiquidityFromAmounts(SQRT_PRICE_1_1, MIN_TICK, MAX_TICK, 1000000, 1000000).toInt256(),
                0
            ),
            ZERO_BYTES
        );
        positionManager.modifyLiquidity(
            poolKey,
            IPoolManager.ModifyLiquidityParams(
                0, 60, calculateLiquidityFromAmounts(SQRT_PRICE_1_1, 0, 60, 100, 100).toInt256(), 0
            ),
            ZERO_BYTES
        );
        positionManager.modifyLiquidity(
            poolKey,
            IPoolManager.ModifyLiquidityParams(
                -120, 0, calculateLiquidityFromAmounts(SQRT_PRICE_1_1, -120, 0, 100, 100).toInt256(), 0
            ),
            ZERO_BYTES
        );
    }

    function calculateLiquidityFromAmounts(
        uint160 sqrtRatioX96,
        int24 tickLower,
        int24 tickUpper,
        uint256 amount0,
        uint256 amount1
    ) internal pure returns (uint128 liquidity) {
        uint160 sqrtRatioAX96 = TickMath.getSqrtPriceAtTick(tickLower);
        uint160 sqrtRatioBX96 = TickMath.getSqrtPriceAtTick(tickUpper);
        liquidity =
            LiquidityAmounts.getLiquidityForAmounts(sqrtRatioX96, sqrtRatioAX96, sqrtRatioBX96, amount0, amount1);
    }

    function getExactInputParams(MockERC20[] memory _tokenPath, uint256 amountIn)
        internal
        view
        returns (IQuoter.QuoteExactParams memory params)
    {
        PathKey[] memory path = new PathKey[](_tokenPath.length - 1);
        for (uint256 i = 0; i < _tokenPath.length - 1; i++) {
            path[i] = PathKey(Currency.wrap(address(_tokenPath[i + 1])), 3000, 60, IHooks(address(0)), bytes(""));
        }

        params.exactCurrency = Currency.wrap(address(_tokenPath[0]));
        params.path = path;
        params.recipient = address(this);
        params.exactAmount = uint128(amountIn);
    }

    function getExactOutputParams(MockERC20[] memory _tokenPath, uint256 amountOut)
        internal
        view
        returns (IQuoter.QuoteExactParams memory params)
    {
        PathKey[] memory path = new PathKey[](_tokenPath.length - 1);
        for (uint256 i = _tokenPath.length - 1; i > 0; i--) {
            path[i - 1] = PathKey(Currency.wrap(address(_tokenPath[i - 1])), 3000, 60, IHooks(address(0)), bytes(""));
        }

        params.exactCurrency = Currency.wrap(address(_tokenPath[_tokenPath.length - 1]));
        params.path = path;
        params.recipient = address(this);
        params.exactAmount = uint128(amountOut);
    }
}
