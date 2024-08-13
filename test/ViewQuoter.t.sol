// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {Test} from "forge-std/Test.sol";
import {ViewQuoter} from "src/lens/ViewQuoter.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IHooks} from "lib/v4-core/src/interfaces/IHooks.sol";
import {BalanceDelta} from "lib/v4-core/src/types/BalanceDelta.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

contract ViewViewQuoterTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    Vm internal constant _vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
    uint24 internal constant TICK_SPACING = 2;

    ViewQuoter public quoter;

    PoolId id;

    function setUp() public {
        deployFreshManagerAndRouters();
        (currency0, currency1) = deployMintAndApprove2Currencies();

        (key, id) = initPoolAndAddLiquidity(
            currency0, currency1, IHooks(address(0)), TICK_SPACING * 50, SQRT_PRICE_1_1, ZERO_BYTES
        );

        quoter = new ViewQuoter(manager);
    }

    function testQuote() public {
        // exact input zero for one
        (,,, uint32 initializedTicksCrossed) = _quote(true, -0.001 ether);
        assertEq(initializedTicksCrossed, 1);

        // exact output zero for one
        (,,, initializedTicksCrossed) = _quote(true, 0.001 ether);
        assertEq(initializedTicksCrossed, 1);

        // exact input one for zero
        (,,, initializedTicksCrossed) = _quote(false, -0.001 ether);
        assertEq(initializedTicksCrossed, 1);

        // exact output one for zero
        (,,, initializedTicksCrossed) = _quote(false, 0.001 ether);
        assertEq(initializedTicksCrossed, 1);
    }

    // these swaps are more than the pool has liquidity for
    function testLargeQuote() public {
        (,,, uint32 initializedTicksCrossed) = _quote(true, -1 ether);
        assertEq(initializedTicksCrossed, 2);
        (,,, initializedTicksCrossed) = _quote(false, -1 ether);
        assertEq(initializedTicksCrossed, 3);
        // the pool has no more liquidity for this quote
        (int256 amount0, int256 amount1, uint160 sqrtPriceAfterX96, uint32 initializedTicksCrossed2) =
            quoter.quoteSingle(key, IPoolManager.SwapParams(false, -1 ether, MAX_PRICE_LIMIT));
        assertEq(amount0, 0);
        assertEq(amount1, 0);
        assertEq(sqrtPriceAfterX96, 0); // undefined behavior
        assertEq(initializedTicksCrossed2, 1);
    }

    // add more liquidity and swap into it
    function testAddLiquidityAndSwap() public {
        IPoolManager.ModifyLiquidityParams memory params =
            IPoolManager.ModifyLiquidityParams({tickLower: 100, tickUpper: 200, liquidityDelta: 2e18, salt: 0});
        modifyLiquidityRouter.modifyLiquidity(key, params, ZERO_BYTES);
        (,,, uint32 initializedTicksCrossed) = _quote(false, -1 ether);
        assertEq(initializedTicksCrossed, 4);
    }

    function testAddLiquidityAndSwap_fuzz(
        int24 tickLower,
        int24 tickUpper,
        uint64 liquidityDelta,
        bool zeroForOne,
        int64 amountSpecified
    ) public {
        _vm.assume(liquidityDelta != 0);
        _vm.assume(amountSpecified != 0);
        _vm.assume(tickLower >= TickMath.MIN_TICK);
        _vm.assume(tickUpper <= TickMath.MAX_TICK);
        _vm.assume(int64(tickUpper) - int64(tickLower) >= int64(int24(TICK_SPACING)));

        tickLower = _align(tickLower);
        tickUpper = _align(tickUpper);
        IPoolManager.ModifyLiquidityParams memory params = IPoolManager.ModifyLiquidityParams({
            tickLower: tickLower,
            tickUpper: tickUpper,
            liquidityDelta: int128(uint128(liquidityDelta)),
            salt: 0
        });
        modifyLiquidityRouter.modifyLiquidity(key, params, ZERO_BYTES);
        _quote(zeroForOne, amountSpecified);
    }

    function testAddLiquidityAndSwapTwice_fuzz(
        int24 tickLower,
        int24 tickUpper,
        uint64 liquidityDelta,
        bool zeroForOne,
        int64 amountSpecified,
        int24 tickLower2,
        int24 tickUpper2,
        bool zeroForOne2,
        int64 amountSpecified2
    ) public {
        testAddLiquidityAndSwap_fuzz(tickLower, tickUpper, liquidityDelta, zeroForOne, amountSpecified);
        // avoid errors with too little liquidity
        uint64 liquidityDelta2 = 1e18;
        testAddLiquidityAndSwap_fuzz(tickLower2, tickUpper2, liquidityDelta2, zeroForOne2, amountSpecified2);
    }

    /// @notice Aligns a tick to the nearest usable tick
    function _align(int24 tick) internal pure returns (int24 alignedTick) {
        if (tick < 0) {
            tick -= int24(TICK_SPACING);
        }
        alignedTick = tick / int24(TICK_SPACING) * int24(TICK_SPACING);
    }

    /// @notice Quotes a swap and executes it, asserting that the outputs match
    function _quote(bool zeroForOne, int256 amountSpecified)
        internal
        returns (int256 amount0, int256 amount1, uint160 sqrtPriceAfterX96, uint32 initializedTicksCrossed)
    {
        uint160 sqrtPriceLimitX96 = zeroForOne ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT;
        (amount0, amount1, sqrtPriceAfterX96, initializedTicksCrossed) =
            quoter.quoteSingle(key, IPoolManager.SwapParams(zeroForOne, amountSpecified, sqrtPriceLimitX96));
        if (amount0 == 0 && amount1 == 0) {
            // pool has no liquidity for this quote
            vm.expectRevert(); // PriceLimitAlreadyExceeded
            swap(key, zeroForOne, amountSpecified, ZERO_BYTES);
        } else {
            BalanceDelta swapDelta = swap(key, zeroForOne, amountSpecified, ZERO_BYTES);
            (uint160 realSqrtPriceX96,,,) = manager.getSlot0(id);
            assertEq(swapDelta.amount0(), amount0);
            assertEq(swapDelta.amount1(), amount1);
            assertEq(sqrtPriceAfterX96, realSqrtPriceX96);
        }
    }
}
