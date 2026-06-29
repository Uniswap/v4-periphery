// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {FixedPoint96} from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {IERC721} from "forge-std/interfaces/IERC721.sol";

import {PosmTestSetup} from "./shared/PosmTestSetup.sol";
import {MockSwapRoute} from "./mocks/MockSwapRoute.sol";
import {SwapAndAdd} from "../src/SwapAndAdd.sol";
import {ISwapAndAdd} from "../src/interfaces/ISwapAndAdd.sol";
import {IUniversalRouter} from "../src/interfaces/external/IUniversalRouter.sol";

/// @notice SwapAndAdd tests (route-first + fee-aware). The empty-route cases exercise the same-pool path
///         (fee-aware sizing, flash-take, mint-to-contract, same-pool reconcile, trim, dust sweep, post-unlock
///         NFT transfer); the routed cases drive a MockSwapRoute through the route-before-mint path, covering
///         under/over-conversion (bidirectional reconcile), better-than-mid capture, and cheaper-than-pool-fee
///         routes. End-to-end integration against the REAL Universal Router lives in test-integration/.
contract SwapAndAddTest is PosmTestSetup {
    using StateLibrary for IPoolManager;
    using CurrencyLibrary for Currency;

    SwapAndAdd zap;
    MockSwapRoute route;
    int24 constant TICK_LOWER = -600;
    int24 constant TICK_UPPER = 600;
    /// @dev abi.encode(bytes commands, bytes[] inputs) — a non-empty route payload the mock ignores.
    bytes constant ROUTE_PAYLOAD = abi.encode(bytes(""), new bytes[](0));

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();
        deployAndApprovePosm(manager);

        (key,) = initPoolAndAddLiquidity(currency0, currency1, IHooks(address(0)), 3000, SQRT_PRICE_1_1);
        seedMoreLiquidity(key, 1_000e18, 1_000e18);

        route = new MockSwapRoute(permit2);
        zap = new SwapAndAdd(manager, permit2, lpm, IUniversalRouter(address(route)));
        // fund the mock route's off-venue inventory so it can deliver the deficit token.
        MockERC20(Currency.unwrap(currency0)).mint(address(route), 1_000_000e18);
        MockERC20(Currency.unwrap(currency1)).mint(address(route), 1_000_000e18);

        seedBalance(address(this));
        _approveZap(currency0);
        _approveZap(currency1);

        // native pool (currency0 == native ETH) with depth for the native add test.
        vm.deal(address(this), 1_000 ether);
        (nativeKey,) = initPoolAndAddLiquidityETH(
            CurrencyLibrary.ADDRESS_ZERO, currency1, IHooks(address(0)), 3000, SQRT_PRICE_1_1, 1 ether
        );
        modifyLiquidityRouter.modifyLiquidity{value: 50 ether}(
            nativeKey,
            ModifyLiquidityParams({tickLower: -600, tickUpper: 600, liquidityDelta: int256(uint256(200e18)), salt: 0}),
            ""
        );
    }

    function _approveZap(Currency c) internal {
        MockERC20(Currency.unwrap(c)).approve(address(permit2), type(uint256).max);
        permit2.approve(Currency.unwrap(c), address(zap), type(uint160).max, type(uint48).max);
    }

    function _addParams(uint256 amount0In, uint256 amount1In)
        internal
        view
        returns (ISwapAndAdd.AddParams memory)
    {
        return ISwapAndAdd.AddParams({
            poolKey: key,
            tickLower: TICK_LOWER,
            tickUpper: TICK_UPPER,
            amount0In: amount0In,
            amount1In: amount1In,
            route: "",
            minLiquidity: 0,
            recipient: address(this),
            hookData: "",
            deadline: block.timestamp + 1
        });
    }

    function test_add_singleToken1() public {
        uint256 amountIn = 10e18;
        uint256 c0Before = currency0.balanceOf(address(this));

        (uint256 tokenId, uint128 liq, uint256 a0, uint256 a1) = zap.add(_addParams(0, amountIn));

        assertEq(IERC721(address(lpm)).ownerOf(tokenId), address(this), "user owns NFT");
        assertGt(liq, 0, "liquidity minted");
        assertGt(a0, 0, "token0 deployed");
        assertGt(a1, 0, "token1 deployed");
        // dust lands in the input token (token1); the swapped-into token0 returns ~nothing.
        assertApproxEqAbs(currency0.balanceOf(address(this)), c0Before, 5, "no token0 dust to user");
        // contract holds nothing
        assertEq(currency0.balanceOf(address(zap)), 0, "zap token0 == 0");
        assertEq(currency1.balanceOf(address(zap)), 0, "zap token1 == 0");
    }

    function test_add_singleToken0() public {
        uint256 amountIn = 10e18;
        uint256 c1Before = currency1.balanceOf(address(this));

        (uint256 tokenId, uint128 liq,,) = zap.add(_addParams(amountIn, 0));

        assertEq(IERC721(address(lpm)).ownerOf(tokenId), address(this), "user owns NFT");
        assertGt(liq, 0, "liquidity minted");
        // dust lands in the input token (token0); the swapped-into token1 returns ~nothing.
        assertApproxEqAbs(currency1.balanceOf(address(this)), c1Before, 5, "no token1 dust to user");
        assertEq(currency0.balanceOf(address(zap)), 0, "zap token0 == 0");
        assertEq(currency1.balanceOf(address(zap)), 0, "zap token1 == 0");
    }

    function test_add_mixedRatio() public {
        (uint256 tokenId, uint128 liq,,) = zap.add(_addParams(3e18, 10e18));
        assertEq(IERC721(address(lpm)).ownerOf(tokenId), address(this), "user owns NFT");
        assertGt(liq, 0, "liquidity minted");
        assertEq(currency0.balanceOf(address(zap)), 0, "zap token0 == 0");
        assertEq(currency1.balanceOf(address(zap)), 0, "zap token1 == 0");
    }

    /// @notice Option C deploys the *actual* max the budget supports, so returned dust is tiny (the genuine
    ///         slippage shortfall), in the input token.
    function test_add_lowDust() public {
        uint256 amountIn = 10e18;
        uint256 c0Before = currency0.balanceOf(address(this));
        uint256 c1Before = currency1.balanceOf(address(this));

        zap.add(_addParams(0, amountIn));

        // net token1 spent = pulled budget - swept dust. dust returned should be a small fraction of the budget.
        uint256 dust1 = currency1.balanceOf(address(this)) + amountIn - c1Before;
        // measured ~15 bps of budget here (0.3% fee pool, ~half the budget swapped) — the genuine slippage shortfall.
        assertLt(dust1, amountIn / 50, "token1 dust < 2% of budget");
        assertApproxEqAbs(currency0.balanceOf(address(this)), c0Before, 5, "no token0 dust");
        assertEq(currency0.balanceOf(address(zap)), 0, "zap token0 == 0");
        assertEq(currency1.balanceOf(address(zap)), 0, "zap token1 == 0");
    }

    function test_add_revertsOnMinLiquidity() public {
        ISwapAndAdd.AddParams memory p = _addParams(0, 10e18);
        p.minLiquidity = type(uint128).max; // impossible floor
        vm.expectRevert();
        zap.add(p);
    }

    function _rebalanceParams(uint256 tokenId, uint128 liquidityToMove)
        internal
        view
        returns (ISwapAndAdd.RebalanceParams memory)
    {
        return ISwapAndAdd.RebalanceParams({
            tokenId: tokenId,
            liquidityToMove: liquidityToMove,
            newTickLower: -1200,
            newTickUpper: 1200,
            route: "",
            minLiquidity: 0,
            recipient: address(this),
            hookData: "",
            deadline: block.timestamp + 1
        });
    }

    function test_rebalance_full() public {
        (uint256 tokenId,,,) = zap.add(_addParams(0, 10e18));
        IERC721(address(lpm)).setApprovalForAll(address(zap), true);

        uint128 posLiq = lpm.getPositionLiquidity(tokenId);
        (uint256 newTokenId, uint128 newLiq,,) = zap.rebalance(_rebalanceParams(tokenId, posLiq));

        assertEq(IERC721(address(lpm)).ownerOf(newTokenId), address(this), "user owns new NFT");
        assertGt(newLiq, 0, "new liquidity minted");
        assertEq(lpm.getPositionLiquidity(tokenId), 0, "old position fully emptied");
        assertEq(currency0.balanceOf(address(zap)), 0, "zap token0 == 0");
        assertEq(currency1.balanceOf(address(zap)), 0, "zap token1 == 0");
    }

    function test_rebalance_partial() public {
        (uint256 tokenId,,,) = zap.add(_addParams(0, 10e18));
        IERC721(address(lpm)).setApprovalForAll(address(zap), true);

        uint128 posLiq = lpm.getPositionLiquidity(tokenId);
        uint128 half = posLiq / 2;
        (uint256 newTokenId, uint128 newLiq,,) = zap.rebalance(_rebalanceParams(tokenId, half));

        assertEq(IERC721(address(lpm)).ownerOf(newTokenId), address(this), "user owns new NFT");
        assertGt(newLiq, 0, "new liquidity minted");
        // original position keeps roughly the remaining half
        assertApproxEqAbs(lpm.getPositionLiquidity(tokenId), posLiq - half, 1, "old keeps remainder");
        assertEq(currency0.balanceOf(address(zap)), 0, "zap token0 == 0");
        assertEq(currency1.balanceOf(address(zap)), 0, "zap token1 == 0");
    }

    function test_add_native() public {
        uint256 nativeIn = 1e17; // 0.1 ETH, native is currency0
        uint256 c1Before = currency1.balanceOf(address(this));

        ISwapAndAdd.AddParams memory p = ISwapAndAdd.AddParams({
            poolKey: nativeKey,
            tickLower: TICK_LOWER,
            tickUpper: TICK_UPPER,
            amount0In: nativeIn,
            amount1In: 0,
            route: "",
            minLiquidity: 0,
            recipient: address(this),
            hookData: "",
            deadline: block.timestamp + 1
        });

        (uint256 tokenId, uint128 liq,,) = zap.add{value: nativeIn}(p);

        assertEq(IERC721(address(lpm)).ownerOf(tokenId), address(this), "user owns NFT");
        assertGt(liq, 0, "liquidity minted");
        // dust lands in the input token (native); the swapped-into currency1 returns ~nothing.
        assertApproxEqAbs(currency1.balanceOf(address(this)), c1Before, 5, "no token1 dust to user");
        // contract strands nothing
        assertEq(address(zap).balance, 0, "zap eth == 0");
        assertEq(currency1.balanceOf(address(zap)), 0, "zap token1 == 0");
    }

    function test_rebalance_revertsIfNotAuthorized() public {
        (uint256 tokenId,,,) = zap.add(_addParams(0, 10e18));
        // do NOT approve the zap; call from a stranger
        uint128 posLiq = lpm.getPositionLiquidity(tokenId);
        vm.prank(address(0xBEEF));
        vm.expectRevert();
        zap.rebalance(_rebalanceParams(tokenId, posLiq));
    }

    // ─────────────────────────── routed (route-first) cases ───────────────────────────

    /// @dev Config the mock route for a single-token1 budget: it consumes `inputAmount` of token1 (the surplus)
    ///      and returns token0 at `rateMultBps` vs the 1:1 mid (10000 = mid, <10000 worse, >10000 beats mid).
    function _configRoute(uint256 rateMultBps, uint256 inputAmount) internal {
        route.config(
            Currency.unwrap(currency1), Currency.unwrap(currency0), FixedPoint96.Q96, rateMultBps, inputAmount, false
        );
    }

    function _routeAdd(uint256 amount1In) internal view returns (ISwapAndAdd.AddParams memory p) {
        p = _addParams(0, amount1In);
        p.route = ROUTE_PAYLOAD;
    }

    /// @notice Route under-converts (input below the ideal): the same-pool reconcile tops up the deficit in the
    ///         normal direction (surplus token1 -> deficit token0). Position lands cleanly, contract strands nothing.
    function test_add_route_underConverts() public {
        _configRoute(9970, 3e18); // ~mid-0.3%, under the ~5e18 ideal for a 10e18 single-tok1 budget
        (uint256 tokenId, uint128 liq,,) = zap.add(_routeAdd(10e18));
        assertEq(IERC721(address(lpm)).ownerOf(tokenId), address(this), "user owns NFT");
        assertGt(liq, 0, "liquidity minted");
        assertEq(currency0.balanceOf(address(zap)), 0, "zap token0 == 0");
        assertEq(currency1.balanceOf(address(zap)), 0, "zap token1 == 0");
    }

    /// @notice Route over-converts (input above the ideal): the reconcile runs the OTHER direction, selling the
    ///         over-bought deficit (token0) back to the surplus (token1). Exercises the bidirectional reconcile.
    function test_add_route_overConverts() public {
        _configRoute(9970, 7e18); // over the ~5e18 ideal -> ends long token0 -> reconcile sells token0->token1
        (uint256 tokenId, uint128 liq,,) = zap.add(_routeAdd(10e18));
        assertEq(IERC721(address(lpm)).ownerOf(tokenId), address(this), "user owns NFT");
        assertGt(liq, 0, "liquidity minted");
        assertEq(currency0.balanceOf(address(zap)), 0, "zap token0 == 0");
        assertEq(currency1.balanceOf(address(zap)), 0, "zap token1 == 0");
    }

    /// @notice Better-than-mid route: route-first sizes from the (richer) post-route holdings and CAPTURES the
    ///         upside, deploying MORE liquidity than the same-pool (empty-route) path can.
    function test_add_route_betterThanMid_capturesUpside() public {
        uint256 snap = vm.snapshotState();
        (, uint128 samePoolLiq,,) = zap.add(_addParams(0, 10e18)); // same-pool baseline
        vm.revertToState(snap);

        _configRoute(10200, 5e18); // route beats mid by 2%
        (, uint128 routedLiq,,) = zap.add(_routeAdd(10e18));
        assertGt(routedLiq, samePoolLiq, "better-than-mid route deploys MORE than same-pool");
    }

    /// @notice Cheaper-than-pool-fee route (mid-0.05% vs the 0.30% pool): route-first deploys more and returns
    ///         less than the same-pool path, because it sizes from the actually-cheap holdings.
    function test_add_route_cheaper_deploysMoreThanSamePool() public {
        uint256 snap = vm.snapshotState();
        uint256 c1Before = currency1.balanceOf(address(this));
        (, uint128 samePoolLiq,,) = zap.add(_addParams(0, 10e18));
        uint256 samePoolReturned = currency1.balanceOf(address(this)) + 10e18 - c1Before;
        vm.revertToState(snap);

        _configRoute(9995, 5e18); // mid-0.05%, cheaper than the 0.30% pool fee
        c1Before = currency1.balanceOf(address(this));
        (, uint128 routedLiq,,) = zap.add(_routeAdd(10e18));
        uint256 routedReturned = currency1.balanceOf(address(this)) + 10e18 - c1Before;

        assertGt(routedLiq, samePoolLiq, "cheaper route deploys MORE than same-pool");
        assertLt(routedReturned, samePoolReturned, "cheaper route returns LESS than same-pool");
        assertEq(currency0.balanceOf(address(zap)), 0, "zap token0 == 0");
        assertEq(currency1.balanceOf(address(zap)), 0, "zap token1 == 0");
    }

    // ─────────────────────────── failure / edge cases ───────────────────────────

    function test_add_revertsAfterDeadline() public {
        ISwapAndAdd.AddParams memory p = _addParams(0, 10e18);
        vm.warp(p.deadline + 1); // now past the deadline
        vm.expectRevert(abi.encodeWithSelector(ISwapAndAdd.DeadlinePassed.selector, p.deadline));
        zap.add(p);
    }

    function test_rebalance_revertsAfterDeadline() public {
        (uint256 tokenId,,,) = zap.add(_addParams(0, 10e18));
        IERC721(address(lpm)).setApprovalForAll(address(zap), true);
        uint128 posLiq = lpm.getPositionLiquidity(tokenId);
        ISwapAndAdd.RebalanceParams memory p = _rebalanceParams(tokenId, posLiq);
        vm.warp(p.deadline + 1);
        vm.expectRevert(abi.encodeWithSelector(ISwapAndAdd.DeadlinePassed.selector, p.deadline));
        zap.rebalance(p);
    }

    function test_add_native_revertsOnWrongEthValue() public {
        ISwapAndAdd.AddParams memory p = ISwapAndAdd.AddParams({
            poolKey: nativeKey,
            tickLower: TICK_LOWER,
            tickUpper: TICK_UPPER,
            amount0In: 1e17, // native budget
            amount1In: 0,
            route: "",
            minLiquidity: 0,
            recipient: address(this),
            hookData: "",
            deadline: block.timestamp + 1
        });
        // msg.value (1e17 - 1) != amount0In (1e17) -> InvalidEthValue
        vm.expectRevert(ISwapAndAdd.InvalidEthValue.selector);
        zap.add{value: 1e17 - 1}(p);
    }

    /// @notice Reachable-but-violated floor: set minLiquidity one wei above the realized post-trim liquidity, so
    ///         the trim brings the final position just under the floor -> revert. (Distinct from the impossible
    ///         type(uint128).max case; this exercises the floor at a realistic boundary.)
    function test_add_revertsWhenTrimUndercutsFloor() public {
        ISwapAndAdd.AddParams memory p = _addParams(0, 10e18);
        uint256 snap = vm.snapshotState();
        (, uint128 liq,,) = zap.add(p); // measure the realized liquidity
        vm.revertToState(snap); // restore pre-add state -> the next add is identical
        p.minLiquidity = liq + 1;
        vm.expectRevert(abi.encodeWithSelector(ISwapAndAdd.InsufficientLiquidity.selector, liq + 1, liq));
        zap.add(p);
    }
}
