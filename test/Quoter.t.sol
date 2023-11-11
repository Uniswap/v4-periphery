//SPDX-License-Identifier: UNLICENSED

pragma solidity ^0.8.20;

import "forge-std/console.sol";
import {Test} from "forge-std/Test.sol";
import {ExactInputSingleParams} from "../contracts/libraries/SwapIntention.sol";
import {Quoter} from "../contracts/lens/Quoter.sol";
import {LiquidityAmounts} from "../contracts/libraries/LiquidityAmounts.sol";
import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";
import {BalanceDelta} from "@uniswap/v4-core/contracts/types/BalanceDelta.sol";
import {SafeCast} from "@uniswap/v4-core/contracts/libraries/SafeCast.sol";
import {Deployers} from "@uniswap/v4-core/test/foundry-tests/utils/Deployers.sol";
import {IHooks} from "@uniswap/v4-core/contracts/interfaces/IHooks.sol";
import {PoolModifyPositionTest} from "@uniswap/v4-core/contracts/test/PoolModifyPositionTest.sol";
import {PoolKey} from "@uniswap/v4-core/contracts/types/PoolKey.sol";
import {PoolManager} from "@uniswap/v4-core/contracts/PoolManager.sol";
import {IPoolManager} from "@uniswap/v4-core/contracts/interfaces/IPoolManager.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/contracts/types/Currency.sol";
import {TickMath} from "@uniswap/v4-core/contracts/libraries/TickMath.sol";

contract QuoterTest is Test, Deployers {
    using SafeCast for *;

    // Min tick for full range with tick spacing of 60
    int24 internal constant MIN_TICK = -887220;
    // Max tick for full range with tick spacing of 60
    int24 internal constant MAX_TICK = -MIN_TICK;

    Quoter quoter;

    PoolManager manager;
    PoolModifyPositionTest positionManager;

    MockERC20 token0;
    MockERC20 token1;
    MockERC20 token2;

    PoolKey key01;
    PoolKey key02;

    function setUp() public {
        manager = new PoolManager(500000);
        quoter = new Quoter(address(manager));
        positionManager = new PoolModifyPositionTest(manager);

        token0 = new MockERC20("Test0", "0", 18);
        token0.mint(address(this), 2 ** 128);
        token1 = new MockERC20("Test1", "1", 18);
        token1.mint(address(this), 2 ** 128);
        token2 = new MockERC20("Test2", "2", 18);
        token2.mint(address(this), 2 ** 128);

        key01 = createPoolKey(token0, token1, address(0));
        key02 = createPoolKey(token0, token2, address(0));
        setupPool(key01);
        setupPoolMultiplePositions(key02);
    }

    function testQuoter_noHook_quoteExactInputSingle_zeroForOne_SinglePosition() public {
        uint256 amountIn = 1 ether;
        uint256 expectedAmountOut = 992054607780215625;

        // uint256 prevBalance0 = token0.balanceOf(address(this));
        // uint256 prevBalance1 = token1.balanceOf(address(this));

        ExactInputSingleParams memory params = ExactInputSingleParams({
            poolKey: key01,
            zeroForOne: true,
            recipient: address(this),
            amountIn: uint128(amountIn),
            sqrtPriceLimitX96: 0,
            hookData: ZERO_BYTES
        });

        (BalanceDelta deltas, uint160 sqrtPriceX96After, uint32 initializedTicksCrossed) =
            quoter.quoteExactInputSingle(params);

        console.log(sqrtPriceX96After);
        assertEq(uint128(-deltas.amount1()), expectedAmountOut);
        assertEq(initializedTicksCrossed, 0);
    }

    function testQuoter_noHook_quoteExactInputSingle_ZeroForOne_MultiplePositions() public {
        uint256 amountIn = 10000;
        uint256 expectedAmountOut = 9871;
        uint160 expectedSqrtPriceX96After = 78461846509168490764501028180;

        (BalanceDelta deltas, uint160 sqrtPriceX96After, uint32 initializedTicksCrossed) = quoter.quoteExactInputSingle(
            ExactInputSingleParams({
                poolKey: key02,
                zeroForOne: true,
                recipient: address(this),
                amountIn: uint128(amountIn),
                sqrtPriceLimitX96: 0,
                hookData: ZERO_BYTES
            })
        );

        assertEq(uint128(-deltas.amount1()), expectedAmountOut);
        assertEq(sqrtPriceX96After, expectedSqrtPriceX96After);
        assertEq(initializedTicksCrossed, 2);
    }

    function testQuoter_noHook_quoteExactInputSingle_OneForZero_MultiplePositions() public {
        uint256 amountIn = 10000;
        uint256 expectedAmountOut = 9871;
        uint160 expectedSqrtPriceX96After = 80001962924147897865541384515;

        (BalanceDelta deltas, uint160 sqrtPriceX96After, uint32 initializedTicksCrossed) = quoter.quoteExactInputSingle(
            ExactInputSingleParams({
                poolKey: key02,
                zeroForOne: false,
                recipient: address(this),
                amountIn: uint128(amountIn),
                sqrtPriceLimitX96: 0,
                hookData: ZERO_BYTES
            })
        );

        assertEq(uint128(-deltas.amount0()), expectedAmountOut);
        assertEq(sqrtPriceX96After, expectedSqrtPriceX96After);
        assertEq(initializedTicksCrossed, 2);
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
            poolKey, IPoolManager.ModifyPositionParams(MIN_TICK, MAX_TICK, 200 ether), ZERO_BYTES
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
}
