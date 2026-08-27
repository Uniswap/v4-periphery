// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {BttBase} from "./BttBase.sol";
import {ISwapAndAddHarness} from "./ISwapAndAddHarness.sol";

contract ReconcileTest is BttBase {
    using CurrencyLibrary for Currency;

    address internal constant SINK = address(0xdead);

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
}
