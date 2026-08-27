// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IERC721} from "forge-std/interfaces/IERC721.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {ISwapAndAdd} from "../../../src/interfaces/ISwapAndAdd.sol";
import {IUniversalRouter} from "../../../src/interfaces/external/IUniversalRouter.sol";
import {MockSamePoolRoute} from "../../mocks/MockSamePoolRoute.sol";
import {PositionConfig} from "../../shared/PositionConfig.sol";
import {BttBase} from "./BttBase.sol";
import {ISwapAndAddHarness} from "./ISwapAndAddHarness.sol";

contract ExecuteRouteTest is BttBase {
    using CurrencyLibrary for Currency;

    function test_WhenRouterHoldsNoNative_DoesNotSweep() public {
        // it does not issue a sweep
        _configRoute(10000, 1e18);
        _fundZap(currency1, 10e18);
        zap.exposedEnsureApproved(currency1);

        ISwapAndAddHarness.CoreParams memory cp = _core(key, 0, 10e18);
        cp.route = ROUTE_PAYLOAD;
        uint256 zapEthBefore = address(zap).balance;

        zap.exposedExecuteRoute(cp);

        assertEq(address(zap).balance, zapEthBefore, "no native sweep");
        assertEq(address(route).balance, 0, "router native empty");
    }

    function test_WhenRouterHoldsNative_SweepsFullBalance() public {
        // it sweeps the full native balance back to the zap
        _configRoute(10000, 0);
        vm.deal(address(route), 1 ether);

        ISwapAndAddHarness.CoreParams memory cp = _core(key, 0, 0);
        cp.route = ROUTE_PAYLOAD;
        uint256 zapEthBefore = address(zap).balance;

        zap.exposedExecuteRoute(cp);

        assertEq(address(route).balance, 0, "router emptied");
        assertEq(address(zap).balance, zapEthBefore + 1 ether, "native reclaimed");
    }

    /// @dev UR balances are permissionlessly sweepable, so the reclaim must fire whenever the router
    ///      holds native. The whole balance joins the budget of the caller.
    function test_WhenRouterHoldsDonatedNative_ItJoinsTheBudget() public {
        // it reclaims the donation into the budget, with and without a pushed value
        _configRoute(10000, 0); // no-op route, consumes nothing
        ISwapAndAdd.AddParams memory p = _routeAdd(10e18);
        p.poolKey = nativeKey;

        uint256 snap = vm.snapshotState();
        (, uint128 liqBaseNoPush,,) = zap.add(p);
        vm.revertToState(snap);

        vm.deal(address(route), 1 ether); // stranded native sitting in the UR
        (, uint128 liqDonatedNoPush,,) = zap.add(p);
        assertEq(address(route).balance, 0, "no push: UR native fully reclaimed");
        assertGt(liqDonatedNoPush, liqBaseNoPush, "reclaimed UR native joined the budget");
        _assertZapIdle();

        p.amount0In = 2 ether;
        snap = vm.snapshotState();
        (, uint128 liqBase,,) = zap.add{value: 2 ether}(p);
        vm.revertToState(snap);

        vm.deal(address(route), 1 ether);
        (, uint128 liqDonated,,) = zap.add{value: 2 ether}(p);
        assertEq(address(route).balance, 0, "value pushed: UR native fully reclaimed");
        assertGt(liqDonated, liqBase, "the reclaimed donation joined the budget");
        _assertZapIdle();
    }

    function test_WhenRouteUnderConverts_ReconcileFillsTheDeficit() public {
        // it fills the remaining deficit in the pool and mints
        _configRoute(9970, 3e18); // ~mid-0.3%, under the ~5e18 ideal for a 10e18 token1 budget
        (uint256 tokenId, uint128 liq,,) = zap.add(_routeAdd(10e18));
        assertEq(IERC721(address(lpm)).ownerOf(tokenId), address(this), "NFT owner");
        assertGt(liq, 0, "liquidity");
        _assertZapIdle();
    }

    function test_WhenRouteOverConverts_ReconcileSellsTheExcess() public {
        // it sells the excess token0 back to token1 and mints
        _configRoute(9970, 7e18); // over the ~5e18 ideal, ends long token0
        (uint256 tokenId, uint128 liq,,) = zap.add(_routeAdd(10e18));
        assertEq(IERC721(address(lpm)).ownerOf(tokenId), address(this), "NFT owner");
        assertGt(liq, 0, "liquidity");
        _assertZapIdle();
    }

    function test_WhenRouteBeatsMid_CapturesTheUpside() public {
        // it deploys more than the same-pool path
        uint256 snap = vm.snapshotState();
        (, uint128 samePoolLiq,,) = zap.add(_addParams(0, 10e18)); // same-pool baseline
        vm.revertToState(snap);

        _configRoute(10200, 5e18); // the route beats mid by 2%
        (, uint128 routedLiq,,) = zap.add(_routeAdd(10e18));
        assertGt(routedLiq, samePoolLiq, "a better-than-mid route deploys more than same-pool");
    }

    function test_WhenRouteIsCheaperThanThePoolFee_DeploysMoreAndReturnsLess() public {
        // it deploys more and returns less than the same-pool path
        uint256 snap = vm.snapshotState();
        uint256 c1Before = currency1.balanceOf(address(this));
        (, uint128 samePoolLiq,,) = zap.add(_addParams(0, 10e18));
        uint256 samePoolReturned = currency1.balanceOf(address(this)) + 10e18 - c1Before;
        vm.revertToState(snap);

        _configRoute(9995, 5e18); // mid-0.05%, cheaper than the 0.30% pool fee
        c1Before = currency1.balanceOf(address(this));
        (, uint128 routedLiq,,) = zap.add(_routeAdd(10e18));
        uint256 routedReturned = currency1.balanceOf(address(this)) + 10e18 - c1Before;

        assertGt(routedLiq, samePoolLiq, "a cheaper route deploys more than same-pool");
        assertLt(routedReturned, samePoolReturned, "a cheaper route returns less than same-pool");
        _assertZapIdle();
    }

    /// @dev A route leg through the target pool accrues LP fees to the position mid-operation, which can
    ///      turn a POSM delta positive. `_deployLiquidity` closes each currency with CLOSE_CURRENCY, so the
    ///      credit is taken and refunded after sizing.
    function test_WhenTheRouteLegHitsTheTargetPool_CreditRetiresTheDebtAndRefunds() public {
        // it completes, funds the flash debt from the fee credit, and refunds the rest in its own denomination
        MockERC20(Currency.unwrap(currency0)).mint(address(this), 1e40);
        MockERC20(Currency.unwrap(currency1)).mint(address(this), 1e40);

        // the target pool: 10% LP fee, spot above the range of the position (tick 1200), no other liquidity
        (PoolKey memory targetKey,) = initPool(
            currency0, currency1, IHooks(address(0)), 100_000, int24(60), TickMath.getSqrtPriceAtTick(int24(1200))
        );
        // deep reserves in an unrelated pool, so the flash-take always finds liquidity
        (PoolKey memory rk,) = initPool(currency0, currency1, IHooks(address(0)), 500, int24(10), SQRT_PRICE_1_1);
        modifyLiquidityRouter.modifyLiquidity(
            rk,
            ModifyLiquidityParams({tickLower: -600_000, tickUpper: 600_000, liquidityDelta: int256(1e30), salt: 0}),
            ""
        );

        // a second zap, wired to a route that swaps in the target pool
        MockSamePoolRoute samePoolRoute = new MockSamePoolRoute(manager, permit2);
        ISwapAndAdd samePoolZap = ISwapAndAdd(
            deployCode(
                "SwapAndAddHarness.sol:SwapAndAddHarness",
                abi.encode(manager, permit2, lpm, IUniversalRouter(address(samePoolRoute)))
            )
        );
        permit2.approve(Currency.unwrap(currency0), address(samePoolZap), type(uint160).max, type(uint48).max);
        permit2.approve(Currency.unwrap(currency1), address(samePoolZap), type(uint160).max, type(uint48).max);
        IERC721(address(lpm)).setApprovalForAll(address(samePoolZap), true);

        // the position, minted straight through POSM (spot above the range: pure token1)
        uint256 tokenId = lpm.nextTokenId();
        mint(
            PositionConfig({poolKey: targetKey, tickLower: TICK_LOWER, tickUpper: TICK_UPPER}), 1e24, address(this), ""
        );

        // the route sells token0 into the same pool, so spot falls into the range of the position and
        // every LP fee on the leg accrues to it
        uint256 routeIn = 5.4e20;
        samePoolRoute.config(targetKey, true, routeIn);

        uint256 c0Before = currency0.balanceOf(address(this));
        uint256 c1Before = currency1.balanceOf(address(this));

        bytes[] memory inputs = new bytes[](1);
        inputs[0] = "";
        ISwapAndAdd.IncreaseParams memory p = _increaseParams(tokenId, routeIn, 0);
        p.route = abi.encode(bytes(hex"00"), inputs);
        p.minLiquidityAdded = 1;
        (uint128 added,,) = samePoolZap.increase(p);

        // 10% LP fee on the whole route input, all of it to this position (the only liquidity in the pool)
        uint256 accruedFee = routeIn / 10;
        uint256 refunded = routeIn - (c0Before - currency0.balanceOf(address(this)));

        assertGt(added, 0, "increase completed with a same-pool route leg");
        assertLt(refunded, accruedFee, "part of the credit funded the flash debt");
        assertGt(refunded, (accruedFee * 85) / 100, "the bulk of the credit is refunded");
        // the credit retires the debt, so no reconcile swap runs and the surplus returns as token1
        assertGt(currency1.balanceOf(address(this)), c1Before, "surplus refunded in its own denomination");
        assertEq(currency0.balanceOf(address(samePoolZap)), 0, "no token0 at rest");
        assertEq(currency1.balanceOf(address(samePoolZap)), 0, "no token1 at rest");
        assertEq(IERC721(address(lpm)).ownerOf(tokenId), address(this), "the owner keeps the NFT");
    }
}
