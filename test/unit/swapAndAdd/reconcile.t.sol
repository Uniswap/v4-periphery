// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {ISwapAndAdd} from "../../../src/interfaces/ISwapAndAdd.sol";
import {BttBase} from "./BttBase.sol";
import {ISwapAndAddHarness} from "./ISwapAndAddHarness.sol";

contract ReconcileTest is BttBase {
    using CurrencyLibrary for Currency;

    address internal constant SINK = address(0xdead);
    bytes4 internal constant CURRENCY_NOT_SETTLED = 0x5212cba1;

    function _deployedMint(uint256 budget0, uint256 budget1)
        internal
        returns (ISwapAndAddHarness.CoreParams memory cp, uint256 tokenId, uint128 lopt, uint256 a0opt, uint256 a1opt)
    {
        _fundZap(currency0, budget0);
        _fundZap(currency1, budget1);
        zap.exposedEnsureApproved(currency0);
        zap.exposedEnsureApproved(currency1);
        cp = _core(key, budget0, budget1);
        (uint160 sl, uint160 su) = _sqrtBounds();
        (lopt, a0opt, a1opt) = zap.exposedPlanLiquidity(cp, sl, su);
        tokenId = zap.exposedDeployLiquidity(cp, lopt, a0opt);
        zap.exposedSweep(currency0, address(this));
        zap.exposedSweep(currency1, address(this));
    }

    function test_WhenHoldingsCoverDeploy_ReturnsZero() public {
        // it returns 0 trimmed and leaves position liquidity unchanged
        (ISwapAndAddHarness.CoreParams memory cp, uint256 tokenId, uint128 lopt, uint256 a0opt, uint256 a1opt) =
            _deployedMint(50e18, 50e18);
        uint128 liqBefore = lpm.getPositionLiquidity(tokenId);
        (uint160 sl, uint160 su) = _sqrtBounds();

        // a0opt <= budget0 and a1opt <= budget1 → early return
        uint128 trimmed = zap.exposedReconcile(cp, tokenId, lopt, a0opt, a1opt, sl, su, 0, 0, address(0), address(0));

        assertEq(trimmed, 0, "trimmed");
        assertEq(lpm.getPositionLiquidity(tokenId), liqBefore, "liquidity unchanged");
    }

    modifier givenDeficitOnToken0() {
        _;
    }

    function test_WhenHeldDeficitCoversFlashDebt() public givenDeficitOnToken0 {
        // it settles without swapping, trimmed is 0, PM deltas close
        (ISwapAndAddHarness.CoreParams memory cp, uint256 tokenId, uint128 lopt, uint256 a0opt, uint256 a1opt) =
            _deployedMint(50e18, 50e18);
        uint128 liqBefore = lpm.getPositionLiquidity(tokenId);
        (uint160 sl, uint160 su) = _sqrtBounds();

        uint256 debt = 1e18;
        _fundZap(currency0, debt);
        cp.budget0 = 0; // force deficitIsCurrency0
        uint256 a0 = a0opt + 1;

        uint128 trimmed = zap.exposedReconcile(cp, tokenId, lopt, a0, a1opt, sl, su, debt, 0, SINK, address(0));

        assertEq(trimmed, 0, "no trim when held deficit covers debt");
        assertEq(lpm.getPositionLiquidity(tokenId), liqBefore, "liquidity unchanged");
    }

    function test_WhenSurplusRemainsAfterSettle_Swaps() public givenDeficitOnToken0 {
        // it swaps surplus for deficit, then closes deltas
        (ISwapAndAddHarness.CoreParams memory cp, uint256 tokenId, uint128 lopt,, uint256 a1opt) =
            _deployedMint(50e18, 50e18);
        uint128 liqBefore = lpm.getPositionLiquidity(tokenId);
        (uint160 sl, uint160 su) = _sqrtBounds();

        uint256 debt = 1e18;
        _fundZap(currency1, 5e18); // surplus only
        cp.budget0 = 0;
        uint256 a0 = debt + 1;

        uint128 trimmed = zap.exposedReconcile(cp, tokenId, lopt, a0, a1opt, sl, su, debt, 0, SINK, address(0));

        assertLe(trimmed, lopt, "trim capped at lopt");
        assertEq(lpm.getPositionLiquidity(tokenId), liqBefore - trimmed, "liquidity reduced by trim only");
    }

    function test_WhenResidualDeficitRemains_Trims() public givenDeficitOnToken0 {
        // it trims newly added liquidity, then closes deltas
        (ISwapAndAddHarness.CoreParams memory cp, uint256 tokenId, uint128 lopt,, uint256 a1opt) =
            _deployedMint(50e18, 50e18);
        uint128 liqBefore = lpm.getPositionLiquidity(tokenId);
        (uint160 sl, uint160 su) = _sqrtBounds();

        // Large flash debt, tiny surplus: swap cannot cover, trim must fire.
        uint256 debt = 10e18;
        _fundZap(currency1, 1e15);
        cp.budget0 = 0;
        uint256 a0 = debt + 1;

        uint128 trimmed = zap.exposedReconcile(cp, tokenId, lopt, a0, a1opt, sl, su, debt, 0, SINK, address(0));

        assertGt(trimmed, 0, "trim fired");
        assertLe(trimmed, lopt, "trim capped at lopt");
        assertEq(lpm.getPositionLiquidity(tokenId), liqBefore - trimmed, "liquidity reduced by trimmed");
    }

    function test_WhenDeficitIsToken1_SellsToken0() public {
        // it selects currency1 as the deficit, sells token0, and closes deltas
        (ISwapAndAddHarness.CoreParams memory cp, uint256 tokenId, uint128 lopt, uint256 a0opt,) =
            _deployedMint(50e18, 50e18);
        uint128 liqBefore = lpm.getPositionLiquidity(tokenId);
        (uint160 sl, uint160 su) = _sqrtBounds();

        uint256 debt = 1e18;
        _fundZap(currency0, 5e18); // surplus token0
        cp.budget1 = 0; // a0opt <= budget0 (still 50e18), a1opt > budget1 → deficit token1
        uint256 a1 = debt + 1;

        uint128 trimmed = zap.exposedReconcile(cp, tokenId, lopt, a0opt, a1, sl, su, 0, debt, address(0), SINK);

        assertLe(trimmed, lopt, "trim capped");
        assertEq(lpm.getPositionLiquidity(tokenId), liqBefore - trimmed, "liquidity reduced by trim only");
    }

    function test_WhenNativePoolDeficit_ClosesDeltas() public {
        // it closes native and token1 deltas and leaves the zap idle
        uint256 budget0 = 1e18;
        uint256 budget1 = 1e18;
        vm.deal(address(zap), budget0);
        _fundZap(currency1, budget1);
        zap.exposedEnsureApproved(currency1);

        ISwapAndAddHarness.CoreParams memory cp = _core(nativeKey, budget0, budget1);
        (uint160 sl, uint160 su) = _sqrtBounds();
        (uint128 lopt, uint256 a0opt,) = zap.exposedPlanLiquidity(cp, sl, su);
        uint256 tokenId = zap.exposedDeployLiquidity(cp, lopt, a0opt);

        uint256 debt = 1e17;
        vm.deal(address(zap), address(zap).balance + 5e17); // native surplus
        cp.budget1 = 0;
        uint256 a1 = debt + 1;

        uint128 trimmed = zap.exposedReconcile(cp, tokenId, lopt, a0opt, a1, sl, su, 0, debt, address(0), SINK);

        assertLe(trimmed, lopt, "trim capped");
        assertEq(lpm.getPositionLiquidity(tokenId), lopt - trimmed, "native liquidity");
    }

    // the token->liquidity inverse of the trim, driven end to end through `add`

    /// @dev A pool at `sqrtPrice` with a full-domain band of `depth`, plus deep reserves for the flash-take.
    function _trimPool(uint24 fee, int24 spacing, uint256 depth) internal returns (PoolKey memory k) {
        MockERC20(Currency.unwrap(currency0)).mint(address(this), 1e45);
        MockERC20(Currency.unwrap(currency1)).mint(address(this), 1e45);
        (k,) = initPool(currency0, currency1, IHooks(address(0)), fee, spacing, SQRT_PRICE_1_1);
        modifyLiquidityRouter.modifyLiquidity(
            k,
            ModifyLiquidityParams({tickLower: -600_000, tickUpper: 600_000, liquidityDelta: int256(depth), salt: 0}),
            ""
        );
        // a deep unrelated reserve pool, so the flash-take never hits a drained PoolManager
        (PoolKey memory rk,) = initPool(currency0, currency1, IHooks(address(0)), 10000, int24(200), SQRT_PRICE_1_1);
        modifyLiquidityRouter.modifyLiquidity(
            rk,
            ModifyLiquidityParams({tickLower: -600_000, tickUpper: 600_000, liquidityDelta: int256(1e30), salt: 0}),
            ""
        );
    }

    function _trimAdd(PoolKey memory k, int24 tl, int24 tu, uint256 a0, uint256 a1, uint256 minLiq)
        internal
        returns (bool reverted, bytes4 sel, uint128 liq)
    {
        ISwapAndAdd.AddParams memory p = _addParams(tl, tu, a0, a1);
        p.poolKey = k;
        p.minLiquidity = minLiq;
        try zap.add(p) returns (uint256, uint128 l, uint256, uint256) {
            liq = l;
        } catch (bytes memory data) {
            reverted = true;
            if (data.length >= 4) sel = bytes4(data);
        }
    }

    /// @dev The uncapped trim must always free the flash debt, so its inverse has to round up.
    function test_WhenTheBudgetIsLargeAndSingleSided_TrimFreesTheDebt() public {
        // it mints without leaving a currency unsettled
        PoolKey memory k = _trimPool(100, 60, 1e34);
        (bool reverted, bytes4 sel, uint128 liq) = _trimAdd(k, -60, 60, 0, 4.4e30, 1);
        assertFalse(reverted, string.concat("must not revert, got selector ", vm.toString(sel)));
        assertGt(liq, 0, "liquidity minted");
        _assertZapIdle();
    }

    /// @dev Budgets inside the ~1-wei mint/burn rounding toll of the pool.
    function test_WhenTheBudgetIsDustAndTheFloorIsSet_SurfacesInsufficientLiquidity() public {
        // it reverts with {InsufficientLiquidity}
        PoolKey memory k = _trimPool(500, 1, 1e24);
        (bool reverted, bytes4 sel,) = _trimAdd(k, -10, 6000, 259, 0, 1);
        assertTrue(reverted, "a dust budget must revert");
        assertEq(sel, ISwapAndAdd.InsufficientLiquidity.selector, "a non-zero floor surfaces InsufficientLiquidity");
    }

    /// @dev A zero floor is the documented opt-out, so the rounding toll surfaces as the v4 error.
    function test_WhenTheBudgetIsDustAndTheFloorIsZero_SurfacesCurrencyNotSettled() public {
        // it reverts with {CurrencyNotSettled}
        PoolKey memory k = _trimPool(500, 1, 1e24);
        (bool reverted, bytes4 sel,) = _trimAdd(k, -10, 6000, 259, 0, 0);
        assertTrue(reverted, "a dust budget must revert");
        assertEq(sel, CURRENCY_NOT_SETTLED, "a zero floor lets CurrencyNotSettled surface");
    }
}
