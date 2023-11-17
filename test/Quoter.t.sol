//SPDX-License-Identifier: UNLICENSED

pragma solidity ^0.8.20;

import "forge-std/console.sol";
import {Test} from "forge-std/Test.sol";
import "../contracts/libraries/SwapIntention.sol";
import {IQuoter} from "../contracts/interfaces/IQuoter.sol";
import {Quoter} from "../contracts/lens/Quoter.sol";
import {LiquidityAmounts} from "../contracts/libraries/LiquidityAmounts.sol";
import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";
import {BalanceDelta} from "@uniswap/v4-core/contracts/types/BalanceDelta.sol";
import {SafeCast} from "@uniswap/v4-core/contracts/libraries/SafeCast.sol";
import {Deployers} from "@uniswap/v4-core/test/foundry-tests/utils/Deployers.sol";
import {IHooks} from "@uniswap/v4-core/contracts/interfaces/IHooks.sol";
import {PoolModifyPositionTest} from "@uniswap/v4-core/contracts/test/PoolModifyPositionTest.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/contracts/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/contracts/types/PoolKey.sol";
import {PoolManager} from "@uniswap/v4-core/contracts/PoolManager.sol";
import {IPoolManager} from "@uniswap/v4-core/contracts/interfaces/IPoolManager.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/contracts/types/Currency.sol";
import {TickMath} from "@uniswap/v4-core/contracts/libraries/TickMath.sol";

contract QuoterTest is Test, Deployers {
    using SafeCast for *;
    using PoolIdLibrary for PoolKey;

    // Min tick for full range with tick spacing of 60
    int24 internal constant MIN_TICK = -887220;
    // Max tick for full range with tick spacing of 60
    int24 internal constant MAX_TICK = -MIN_TICK;

    uint256 internal constant CONTROLLER_GAS_LIMIT = 500000;

    Quoter quoter;

    PoolManager manager;
    PoolModifyPositionTest positionManager;

    MockERC20 token0;
    MockERC20 token1;
    MockERC20 token2;

    PoolKey key01;
    PoolKey key02;
    PoolKey key12;

    MockERC20[] tokenPath;

    function setUp() public {
        manager = new PoolManager(CONTROLLER_GAS_LIMIT);
        quoter = new Quoter(address(manager));
        positionManager = new PoolModifyPositionTest(manager);

        // salts are chosen so that address(token0) < address(token2) && address(1) < address(token2)
        bytes32 salt1 = "ffff";
        bytes32 salt2 = "gm";
        token0 = new MockERC20{salt: salt1}("Test0", "0", 18);
        token0.mint(address(this), 2 ** 128);
        token1 = new MockERC20{salt: salt2}("Test1", "1", 18);
        token1.mint(address(this), 2 ** 128);
        token2 = new MockERC20("Test2", "2", 18);
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
            ExactInputSingleParams({
                poolKey: key02,
                zeroForOne: true,
                recipient: address(this),
                amountIn: uint128(amountIn),
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
            ExactInputSingleParams({
                poolKey: key02,
                zeroForOne: false,
                recipient: address(this),
                amountIn: uint128(amountIn),
                sqrtPriceLimitX96: 0,
                hookData: ZERO_BYTES
            })
        );

        assertEq(uint128(-deltaAmounts[0]), expectedAmountOut);
        assertEq(sqrtPriceX96After, expectedSqrtPriceX96After);
        assertEq(initializedTicksLoaded, 2);
    }

    function testQuoter_quoteExactInputBatch() public {
        bool[] memory zeroForOnes = new bool[](2);
        zeroForOnes[0] = true;
        zeroForOnes[1] = false;

        address[] memory recipients = new address[](2);
        recipients[0] = address(this);
        recipients[1] = address(this);

        // repeat for the three arrays below
        uint128[] memory amountIns = new uint128[](2);
        amountIns[0] = 10000;
        amountIns[1] = 10000;

        uint160[] memory sqrtPriceLimitX96s = new uint160[](2);
        sqrtPriceLimitX96s[0] = 0;
        sqrtPriceLimitX96s[1] = 0;

        bytes[] memory hookData = new bytes[](2);
        hookData[0] = ZERO_BYTES;
        hookData[1] = ZERO_BYTES;

        (
            IQuoter.PoolDeltas[] memory deltas,
            uint160[] memory sqrtPriceX96AfterList,
            uint32[] memory initializedTicksLoadedList
        ) = quoter.quoteExactInputBatch(
            ExactInputSingleBatchParams({
                poolKey: key02,
                zeroForOnes: zeroForOnes,
                recipients: recipients,
                amountIns: amountIns,
                sqrtPriceLimitX96s: sqrtPriceLimitX96s,
                hookData: hookData
            })
        );
        assertEq(deltas.length, 2);
        assertEq(uint128(-deltas[0].currency1Delta), 9871);
        assertEq(uint128(-deltas[1].currency0Delta), 9871);

        assertEq(sqrtPriceX96AfterList.length, 2);
        assertEq(sqrtPriceX96AfterList[0], 78461846509168490764501028180);
        assertEq(sqrtPriceX96AfterList[1], 80001962924147897865541384515);

        assertEq(initializedTicksLoadedList.length, 2);
        assertEq(initializedTicksLoadedList[0], 2);
        assertEq(initializedTicksLoadedList[1], 2);
    }

    function testQuoter_quoteExactInput_0to2_2TicksLoaded() public {
        tokenPath.push(token0);
        tokenPath.push(token2);
        ExactInputParams memory params = getExactInputParams(tokenPath, 10000);

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
        ExactInputParams memory params = getExactInputParams(tokenPath, 6200);

        (
            int128[] memory deltaAmounts,
            uint160[] memory sqrtPriceX96AfterList,
            uint32[] memory initializedTicksLoadedList
        ) = quoter.quoteExactInput(params);

        assertEq(uint128(-deltaAmounts[1]), 6143);
        assertEq(sqrtPriceX96AfterList[0], 78757224507315167622282810783);
        assertEq(initializedTicksLoadedList[0], 1);
    }

    function testQuoter_quoteExactInput_0to2_1TicksLoaded() public {
        tokenPath.push(token0);
        tokenPath.push(token2);

        // The swap amount is set such that the active tick after the swap is -60.
        // -60 is an initialized tick for this pool. We check that we don't count it.
        ExactInputParams memory params = getExactInputParams(tokenPath, 4000);

        (
            int128[] memory deltaAmounts,
            uint160[] memory sqrtPriceX96AfterList,
            uint32[] memory initializedTicksLoadedList
        ) = quoter.quoteExactInput(params);

        assertEq(uint128(-deltaAmounts[1]), 3971);
        assertEq(sqrtPriceX96AfterList[0], 78926452400586371254602774705);
        assertEq(initializedTicksLoadedList[0], 1);
    }

    function testQuoter_quoteExactInput_0to2_0TicksLoaded_startingNotInitialized() public {
        tokenPath.push(token0);
        tokenPath.push(token2);
        ExactInputParams memory params = getExactInputParams(tokenPath, 10);

        (
            int128[] memory deltaAmounts,
            uint160[] memory sqrtPriceX96AfterList,
            uint32[] memory initializedTicksLoadedList
        ) = quoter.quoteExactInput(params);

        assertEq(uint128(-deltaAmounts[1]), 8);
        assertEq(sqrtPriceX96AfterList[0], 79227483487511329217250071027);
        assertEq(initializedTicksLoadedList[0], 0);
    }

    function testQuoter_quoteExactInput_0to2_0TicksLoaded_startingInitialized() public {
        setupPoolWithZeroTickInitialized(key02);
        tokenPath.push(token0);
        tokenPath.push(token2);
        ExactInputParams memory params = getExactInputParams(tokenPath, 10);

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
        ExactInputParams memory params = getExactInputParams(tokenPath, 10000);

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
        ExactInputParams memory params = getExactInputParams(tokenPath, 6250);

        (
            int128[] memory deltaAmounts,
            uint160[] memory sqrtPriceX96AfterList,
            uint32[] memory initializedTicksLoadedList
        ) = quoter.quoteExactInput(params);

        assertEq(-deltaAmounts[1], 6190);
        assertEq(sqrtPriceX96AfterList[0], 79705728824507063507279123685);
        assertEq(initializedTicksLoadedList[0], 2);
    }

    function testQuoter_quoteExactInput_2to0_0TicksLoaded_startingInitialized() public {
        setupPoolWithZeroTickInitialized(key02);
        tokenPath.push(token2);
        tokenPath.push(token0);
        ExactInputParams memory params = getExactInputParams(tokenPath, 200);

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
    function testQuoter_quoteExactInput_2to0_0TicksLoaded_startingNotInitialized() public {
        tokenPath.push(token2);
        tokenPath.push(token0);
        ExactInputParams memory params = getExactInputParams(tokenPath, 103);

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
        ExactInputParams memory params = getExactInputParams(tokenPath, 10000);

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
        ExactInputParams memory params = getExactInputParams(tokenPath, 10000);

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

    function createPoolKey(MockERC20 tokenA, MockERC20 tokenB, address hookAddr)
        internal
        pure
        returns (PoolKey memory)
    {
        if (address(tokenA) > address(tokenB)) (tokenA, tokenB) = (tokenB, tokenA);
        return PoolKey(Currency.wrap(address(tokenA)), Currency.wrap(address(tokenB)), 3000, 60, IHooks(hookAddr));
    }

    function setupPool(PoolKey memory poolKey) internal {
        manager.initialize(poolKey, SQRT_RATIO_1_1, ZERO_BYTES);
        MockERC20(Currency.unwrap(poolKey.currency0)).approve(address(positionManager), type(uint256).max);
        MockERC20(Currency.unwrap(poolKey.currency1)).approve(address(positionManager), type(uint256).max);
        positionManager.modifyPosition(
            poolKey,
            IPoolManager.ModifyPositionParams(
                MIN_TICK,
                MAX_TICK,
                calculateLiquidityFromAmounts(SQRT_RATIO_1_1, MIN_TICK, MAX_TICK, 1000000, 1000000).toInt256()
            ),
            ZERO_BYTES
        );
    }

    function setupPoolMultiplePositions(PoolKey memory poolKey) internal {
        manager.initialize(poolKey, SQRT_RATIO_1_1, ZERO_BYTES);
        MockERC20(Currency.unwrap(poolKey.currency0)).approve(address(positionManager), type(uint256).max);
        MockERC20(Currency.unwrap(poolKey.currency1)).approve(address(positionManager), type(uint256).max);
        positionManager.modifyPosition(
            poolKey,
            IPoolManager.ModifyPositionParams(
                MIN_TICK,
                MAX_TICK,
                calculateLiquidityFromAmounts(SQRT_RATIO_1_1, MIN_TICK, MAX_TICK, 1000000, 1000000).toInt256()
            ),
            ZERO_BYTES
        );
        positionManager.modifyPosition(
            poolKey,
            IPoolManager.ModifyPositionParams(
                -60, 60, calculateLiquidityFromAmounts(SQRT_RATIO_1_1, -60, 60, 100, 100).toInt256()
            ),
            ZERO_BYTES
        );
        positionManager.modifyPosition(
            poolKey,
            IPoolManager.ModifyPositionParams(
                -120, 120, calculateLiquidityFromAmounts(SQRT_RATIO_1_1, -120, 120, 100, 100).toInt256()
            ),
            ZERO_BYTES
        );
    }

    function setupPoolWithZeroTickInitialized(PoolKey memory poolKey) internal {
        PoolId poolId = poolKey.toId();
        (uint160 sqrtPriceX96,,,) = manager.getSlot0(poolId);
        if (sqrtPriceX96 == 0) {
            manager.initialize(poolKey, SQRT_RATIO_1_1, ZERO_BYTES);
        }

        MockERC20(Currency.unwrap(poolKey.currency0)).approve(address(positionManager), type(uint256).max);
        MockERC20(Currency.unwrap(poolKey.currency1)).approve(address(positionManager), type(uint256).max);
        positionManager.modifyPosition(
            poolKey,
            IPoolManager.ModifyPositionParams(
                MIN_TICK,
                MAX_TICK,
                calculateLiquidityFromAmounts(SQRT_RATIO_1_1, MIN_TICK, MAX_TICK, 1000000, 1000000).toInt256()
            ),
            ZERO_BYTES
        );
        positionManager.modifyPosition(
            poolKey,
            IPoolManager.ModifyPositionParams(
                0, 60, calculateLiquidityFromAmounts(SQRT_RATIO_1_1, 0, 60, 100, 100).toInt256()
            ),
            ZERO_BYTES
        );
        positionManager.modifyPosition(
            poolKey,
            IPoolManager.ModifyPositionParams(
                -120, 0, calculateLiquidityFromAmounts(SQRT_RATIO_1_1, -120, 0, 100, 100).toInt256()
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
        uint160 sqrtRatioAX96 = TickMath.getSqrtRatioAtTick(tickLower);
        uint160 sqrtRatioBX96 = TickMath.getSqrtRatioAtTick(tickUpper);
        liquidity =
            LiquidityAmounts.getLiquidityForAmounts(sqrtRatioX96, sqrtRatioAX96, sqrtRatioBX96, amount0, amount1);
    }

    function getExactInputParams(MockERC20[] memory _tokenPath, uint256 amountIn)
        internal
        view
        returns (ExactInputParams memory params)
    {
        PathKey[] memory path = new PathKey[](_tokenPath.length - 1);
        for (uint256 i = 0; i < _tokenPath.length - 1; i++) {
            path[i] = PathKey(Currency.wrap(address(_tokenPath[i + 1])), 3000, 60, IHooks(address(0)), bytes(""));
        }

        params.currencyIn = Currency.wrap(address(_tokenPath[0]));
        params.path = path;
        params.recipient = address(this);
        params.amountIn = uint128(amountIn);
    }

    function logTicksLoaded(uint32[] memory num) private view {
        console.logString("=== Num Ticks Crossed ===");
        for (uint256 i = 0; i < num.length; i++) {
            console.logUint(num[i]);
        }
    }

    function logSqrtPrices(uint160[] memory prices) private view {
        console.logString("=== Sqrt Prices After ===");
        for (uint256 i = 0; i < prices.length; i++) {
            console.logUint(prices[i]);
        }
    }

    function logDeltas(int128[] memory deltas) private view {
        console.logString("=== Delta Amounts ===");
        for (uint256 i = 0; i < deltas.length; i++) {
            console.logInt(deltas[i]);
        }
    }
}
