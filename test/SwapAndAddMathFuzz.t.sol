// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {FixedPoint96} from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {LiquidityAmounts} from "../src/libraries/LiquidityAmounts.sol";
import {ISwapAndAdd} from "../src/interfaces/ISwapAndAdd.sol";
import {IUniversalRouter} from "../src/interfaces/external/IUniversalRouter.sol";
import {PosmTestSetup} from "./shared/PosmTestSetup.sol";

/// @notice Behavioral fuzz pins that need a live pool (pure-math coverage is in SwapAndAddMath.t.sol):
///         fee-aware sizing keeps the add dust price-impact-small, and single-sided budgets deploy
///         >= 99.9% of feasible liquidity at any tick.
contract SwapAndAddMathFuzzTest is PosmTestSetup {
    using CurrencyLibrary for Currency;

    // fee-aware sizing: dust-tightness fuzz

    ISwapAndAdd zap;
    address dustRecipient = makeAddr("dustRecipient");

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();
        deployAndApprovePosm(manager);
        zap = ISwapAndAdd(
            deployCode("SwapAndAdd.sol:SwapAndAdd", abi.encode(manager, permit2, lpm, IUniversalRouter(makeAddr("ur"))))
        );
        permit2.approve(Currency.unwrap(currency0), address(zap), type(uint160).max, type(uint48).max);
        permit2.approve(Currency.unwrap(currency1), address(zap), type(uint160).max, type(uint48).max);
    }

    /// @dev With an exact fee discount the dust stays below 10bps for budgets <= 3e20 against 1e24 pool
    ///      liquidity. A broken discount pushes the swap fee into the dust and breaks the bound.
    function testFuzz_add_feeAware_dustStaysImpactSmall(uint24 feeSeed, uint256 b0Seed, uint256 b1Seed) public {
        uint24 fee = uint24(bound(feeSeed, 5000, 100_000)); // 0.5% .. 10%
        uint256 b0 = bound(b0Seed, 0, 3e20);
        uint256 b1 = bound(b1Seed, 0, 3e20);
        vm.assume(b0 + b1 >= 1e16);

        (PoolKey memory k,) = initPool(currency0, currency1, IHooks(address(0)), fee, int24(60), SQRT_PRICE_1_1);
        modifyLiquidityRouter.modifyLiquidity(
            k,
            ModifyLiquidityParams({tickLower: -600_000, tickUpper: 600_000, liquidityDelta: int256(1e24), salt: 0}),
            ""
        );

        (, uint128 liq,,) = zap.add(
            ISwapAndAdd.AddParams({
                poolKey: k,
                tickLower: -600,
                tickUpper: 600,
                amount0In: b0,
                amount1In: b1,
                route: "",
                routeFunding: new ISwapAndAdd.TokenAmount[](0),
                minLiquidity: 1,
                recipient: dustRecipient,
                hookData: "",
                deadline: block.timestamp + 1
            })
        );
        assertGt(liq, 0, "position minted");

        // dust = everything the recipient received, valued at the ~1 pool price
        uint256 dustValue = currency0.balanceOf(dustRecipient) + currency1.balanceOf(dustRecipient);
        uint256 budgetValue = b0 + b1;
        assertLe(dustValue * 10_000, budgetValue * 10, "dust exceeded 10bps: fee-aware sizing is inaccurate");
    }

    // extreme-tick sizing: token1 mirror of the token0 fuzz

    /// @dev Single-sided token1 (range fully below spot) must deploy >= 99.9% of feasible liquidity at
    ///      any tick, through the price<1 numeraire branch.
    function testFuzz_add_extremeTick_token1_fullDeployment(int24 tick, uint256 exp) public {
        tick = int24((bound(int256(tick), -799990, 800000) / 10) * 10);
        uint256 b1 = 10 ** bound(exp, 6, 30);
        uint160 spl = TickMath.getSqrtPriceAtTick(tick - 60);
        uint160 spu = TickMath.getSqrtPriceAtTick(tick);
        // replica of getLiquidityForAmount1 to pre-filter degenerate combos
        uint256 expected = FullMath.mulDiv(b1, FixedPoint96.Q96, spu - spl);
        vm.assume(expected >= 1e6 && expected < 1e33);

        PoolKey memory k = PoolKey({
            currency0: currency0, currency1: currency1, fee: 3000, tickSpacing: 10, hooks: IHooks(address(0))
        });
        manager.initialize(k, TickMath.getSqrtPriceAtTick(tick));
        MockERC20(Currency.unwrap(currency1)).mint(address(this), b1);

        uint128 feasible = LiquidityAmounts.getLiquidityForAmount1(spl, spu, b1);
        (, uint128 liq,,) = zap.add(
            ISwapAndAdd.AddParams({
                poolKey: k,
                tickLower: tick - 60,
                tickUpper: tick,
                amount0In: 0,
                amount1In: b1,
                route: "",
                routeFunding: new ISwapAndAdd.TokenAmount[](0),
                minLiquidity: uint256(feasible) * 999 / 1000,
                recipient: address(this),
                hookData: "",
                deadline: block.timestamp + 1
            })
        );
        assertGe(liq, uint128(uint256(feasible) * 999 / 1000), "full token1 budget deployed at extreme tick");
    }
}
