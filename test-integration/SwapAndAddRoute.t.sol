// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {IERC721} from "forge-std/interfaces/IERC721.sol";

// These libraries build route bytes identical to the copy the UR decodes against.
import {Plan, Planner} from "../test/shared/Planner.sol";
import {Actions} from "../src/libraries/Actions.sol";
import {ActionConstants} from "../src/libraries/ActionConstants.sol";
import {IV4Router} from "../src/interfaces/IV4Router.sol";

import {PosmTestSetup} from "../test/shared/PosmTestSetup.sol";
import {MockRouterDebtSubscriber} from "../test/mocks/MockRouterDebtSubscriber.sol";
import {SwapAndAdd} from "../src/SwapAndAdd.sol";
import {ISwapAndAdd} from "../src/interfaces/ISwapAndAdd.sol";
import {IUniversalRouter} from "../src/interfaces/external/IUniversalRouter.sol";

import {UniversalRouter} from "universal-router/contracts/UniversalRouter.sol";
import {RouterParameters} from "universal-router/contracts/types/RouterParameters.sol";
import {Commands} from "universal-router/contracts/libraries/Commands.sol";

/// @notice Tests the non-empty `route` path: UR.execute runs inside the zap's own PoolManager unlock.
///         The modified UR (`feat/v4-swap-within-existing-unlock`) enables this path. The canonical UR reverts AlreadyUnlocked.
contract SwapAndAddRouteTest is PosmTestSetup {
    using StateLibrary for IPoolManager;
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;

    SwapAndAdd zap;
    UniversalRouter router;
    PoolKey routeKey; // second pool, touched only by the UR route leg

    int24 constant TICK_LOWER = -600;
    int24 constant TICK_UPPER = 600;

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();
        deployAndApprovePosm(manager);

        // target pool for the add
        (key,) = initPoolAndAddLiquidity(currency0, currency1, IHooks(address(0)), 3000, SQRT_PRICE_1_1);
        seedMoreLiquidity(key, 1_000e18, 1_000e18);

        // separate pool (different fee) for the UR route's swap leg
        (routeKey,) = initPoolAndAddLiquidity(currency0, currency1, IHooks(address(0)), 500, SQRT_PRICE_1_1);
        seedMoreLiquidity(routeKey, 1_000e18, 1_000e18);

        // the real modified Universal Router, pointed at this test's PoolManager + Permit2 (v2/v3/migration off)
        RouterParameters memory params = RouterParameters({
            permit2: address(permit2),
            weth9: address(0),
            v2Factory: address(0),
            v3Factory: address(0),
            pairInitCodeHash: bytes32(0),
            poolInitCodeHash: bytes32(0),
            v4PoolManager: address(manager),
            permissionsAdapterFactory: address(0),
            v3NFTPositionManager: address(0),
            v4PositionManager: address(0),
            spokePool: address(0)
        });
        router = new UniversalRouter(params);

        zap = new SwapAndAdd(manager, permit2, lpm, IUniversalRouter(address(router)));

        seedBalance(address(this));
        _approveZap(currency0);
        _approveZap(currency1);
    }

    function _approveZap(Currency c) internal {
        MockERC20(Currency.unwrap(c)).approve(address(permit2), type(uint256).max);
        permit2.approve(Currency.unwrap(c), address(zap), type(uint160).max, type(uint48).max);
    }

    /// @dev Builds a UR route: a single exact-in V4_SWAP of `inCcy` for `outCcy` on `poolKey`.
    function _v4SwapRoute(PoolKey memory poolKey, bool zeroForOne, uint128 amtIn, Currency inCcy, Currency outCcy)
        internal
        pure
        returns (bytes memory)
    {
        bytes memory commands = abi.encodePacked(bytes1(uint8(Commands.V4_SWAP)));
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = _v4SwapInput(poolKey, zeroForOne, amtIn, inCcy, outCcy);
        return abi.encode(commands, inputs);
    }

    /// @dev Builds a UR route that initializes `newKey` (allow-revert, a no-op if it already exists),
    ///      then runs a single exact-in V4_SWAP on `poolKey`.
    function _initAndSwapRoute(
        PoolKey memory newKey,
        uint160 sqrtPriceX96,
        PoolKey memory poolKey,
        bool zeroForOne,
        uint128 amtIn,
        Currency inCcy,
        Currency outCcy
    ) internal pure returns (bytes memory) {
        bytes memory commands = abi.encodePacked(
            bytes1(uint8(Commands.V4_INITIALIZE_POOL)) | Commands.FLAG_ALLOW_REVERT, bytes1(uint8(Commands.V4_SWAP))
        );
        bytes[] memory inputs = new bytes[](2);
        inputs[0] = abi.encode(newKey, sqrtPriceX96);
        inputs[1] = _v4SwapInput(poolKey, zeroForOne, amtIn, inCcy, outCcy);
        return abi.encode(commands, inputs);
    }

    /// @dev Encodes a V4_SWAP plan: exact-in swap, settle from the caller, take to the caller.
    function _v4SwapInput(PoolKey memory poolKey, bool zeroForOne, uint128 amtIn, Currency inCcy, Currency outCcy)
        internal
        pure
        returns (bytes memory)
    {
        IV4Router.ExactInputSingleParams memory sp = IV4Router.ExactInputSingleParams({
            poolKey: poolKey,
            zeroForOne: zeroForOne,
            amountIn: amtIn,
            amountOutMinimum: 0,
            minHopPriceX36: 0,
            hookData: hex""
        });

        Plan memory plan = Planner.init();
        plan = plan.add(Actions.SWAP_EXACT_IN_SINGLE, abi.encode(sp));
        // payerIsUser = true -> UR pulls the input token from its caller (the zap) through Permit2.
        plan = plan.add(Actions.SETTLE, abi.encode(inCcy, ActionConstants.OPEN_DELTA, true));
        // MSG_SENDER inside UR resolves to the zap (UR's caller), so the output lands back in the zap.
        plan = plan.add(Actions.TAKE, abi.encode(outCcy, ActionConstants.MSG_SENDER, ActionConstants.OPEN_DELTA));
        return plan.encode();
    }

    /// @notice Single-token1 budget: the UR route swaps token1 -> token0 on `routeKey` inside the unlock.
    function test_add_singleToken1_viaURRoute() public {
        uint256 amount1In = 10e18;
        uint128 routeAmountIn = 3e18; // sell 3e18 token1 -> token0 on routeKey via UR, reconcile tops up the rest
        uint256 c0Before = currency0.balanceOf(address(this));

        bytes memory route = _v4SwapRoute(routeKey, false, routeAmountIn, currency1, currency0);

        (uint160 routeSpBefore,,,) = manager.getSlot0(routeKey.toId());

        ISwapAndAdd.AddParams memory p = ISwapAndAdd.AddParams({
            poolKey: key,
            tickLower: TICK_LOWER,
            tickUpper: TICK_UPPER,
            amount0In: 0,
            amount1In: amount1In,
            route: route,
            routeFunding: new ISwapAndAdd.TokenAmount[](0),
            minLiquidity: 0,
            sqrtPriceMinX96: 0,
            sqrtPriceMaxX96: type(uint160).max,
            recipient: address(this),
            hookData: "",
            deadline: block.timestamp + 1
        });

        (uint256 tokenId, uint128 liq, uint256 a0, uint256 a1) = zap.add(p);

        assertEq(IERC721(address(lpm)).ownerOf(tokenId), address(this), "user owns NFT");
        assertGt(liq, 0, "liquidity minted");
        assertGt(a0, 0, "token0 deployed");
        assertGt(a1, 0, "token1 deployed");
        assertApproxEqAbs(currency0.balanceOf(address(this)), c0Before, 5, "no token0 dust to user");
        assertEq(currency0.balanceOf(address(zap)), 0, "zap token0 == 0");
        assertEq(currency1.balanceOf(address(zap)), 0, "zap token1 == 0");

        // only the route leg touches routeKey, so a price move there proves the UR route executed
        (uint160 routeSpAfter,,,) = manager.getSlot0(routeKey.toId());
        assertTrue(routeSpAfter != routeSpBefore, "UR route did not execute on the route pool");
        // selling token1 adds token1 to the pool, so sqrtPrice rises
        assertGt(routeSpAfter, routeSpBefore, "selling token1 should raise routeKey's sqrtPrice");
    }

    /// @notice The route spends 2 ether of the 10 ether forwarded. The zap must reclaim the unconsumed
    ///         8 ether from the sweepable UR balance and redeploy it through the reconcile.
    function test_add_native_partialRouteValue_reclaimedFromUR() public {
        (PoolKey memory nativeKey,) = initPoolAndAddLiquidityETH(
            CurrencyLibrary.ADDRESS_ZERO, currency1, IHooks(address(0)), 3000, SQRT_PRICE_1_1, 1 ether
        );
        modifyLiquidityRouter.modifyLiquidity{value: 50 ether}(
            nativeKey,
            ModifyLiquidityParams({tickLower: -600, tickUpper: 600, liquidityDelta: int256(uint256(200e18)), salt: 0}),
            ""
        );
        (PoolKey memory nativeRouteKey,) = initPoolAndAddLiquidityETH(
            CurrencyLibrary.ADDRESS_ZERO, currency1, IHooks(address(0)), 500, SQRT_PRICE_1_1, 1 ether
        );
        modifyLiquidityRouter.modifyLiquidity{value: 50 ether}(
            nativeRouteKey,
            ModifyLiquidityParams({tickLower: -600, tickUpper: 600, liquidityDelta: int256(uint256(200e18)), salt: 0}),
            ""
        );

        vm.deal(address(this), 100 ether);
        bytes memory route = _v4SwapRoute(nativeRouteKey, true, 2 ether, CurrencyLibrary.ADDRESS_ZERO, currency1);

        ISwapAndAdd.AddParams memory p = ISwapAndAdd.AddParams({
            poolKey: nativeKey,
            tickLower: TICK_LOWER,
            tickUpper: TICK_UPPER,
            amount0In: 10 ether,
            amount1In: 0,
            route: route,
            routeFunding: new ISwapAndAdd.TokenAmount[](0),
            minLiquidity: 0,
            sqrtPriceMinX96: 0,
            sqrtPriceMaxX96: type(uint160).max,
            recipient: address(this),
            hookData: "",
            deadline: block.timestamp + 1
        });
        (uint256 tokenId, uint128 liq,,) = zap.add{value: 10 ether}(p);

        assertEq(IERC721(address(lpm)).ownerOf(tokenId), address(this), "user owns NFT");
        assertGt(liq, 0, "liquidity minted");
        assertEq(address(router).balance, 0, "native stranded in UR");
        assertEq(address(zap).balance, 0, "native stranded in zap");
        assertEq(currency1.balanceOf(address(zap)), 0, "token1 stranded in zap");
    }

    /// @dev An uninitialized pool next to `key` and `routeKey` (distinct tick spacing).
    function _freshKey() internal view returns (PoolKey memory) {
        return
            PoolKey({currency0: currency0, currency1: currency1, fee: 3000, tickSpacing: 10, hooks: IHooks(address(0))});
    }

    /// @dev Single-token1 add into `poolKey` with a ±1% band around price 1.
    function _bandedAddParams(PoolKey memory poolKey, uint256 amount1In, bytes memory route)
        internal
        view
        returns (ISwapAndAdd.AddParams memory)
    {
        return ISwapAndAdd.AddParams({
            poolKey: poolKey,
            tickLower: TICK_LOWER,
            tickUpper: TICK_UPPER,
            amount0In: 0,
            amount1In: amount1In,
            route: route,
            routeFunding: new ISwapAndAdd.TokenAmount[](0),
            minLiquidity: 0,
            sqrtPriceMinX96: uint160(uint256(SQRT_PRICE_1_1) * 99 / 100),
            sqrtPriceMaxX96: uint160(uint256(SQRT_PRICE_1_1) * 101 / 100),
            recipient: address(this),
            hookData: "",
            deadline: block.timestamp + 1
        });
    }

    /// @notice The route initializes a fresh pool and does most of the balancing on `routeKey`. The
    ///         remaining imbalance reconciles against the caller's own position, the pool's only liquidity.
    function test_add_uninitializedPool_routeInitializes_smallReconcile() public {
        PoolKey memory newKey = _freshKey();
        (uint160 sqrtBefore,,,) = manager.getSlot0(newKey.toId());
        assertEq(sqrtBefore, 0, "pool starts uninitialized");

        uint256 amount1In = 10e18;
        // a little under half, so the route leaves a small token0 deficit for the reconcile
        bytes memory route = _initAndSwapRoute(newKey, SQRT_PRICE_1_1, routeKey, false, 4.9e18, currency1, currency0);
        uint256 c0Before = currency0.balanceOf(address(this));
        uint256 c1Before = currency1.balanceOf(address(this));
        (uint160 routeSpBefore,,,) = manager.getSlot0(routeKey.toId());

        (uint256 tokenId, uint128 liq,,) = zap.add(_bandedAddParams(newKey, amount1In, route));

        assertEq(IERC721(address(lpm)).ownerOf(tokenId), address(this), "user owns NFT");
        assertEq(manager.getLiquidity(newKey.toId()), liq, "caller is the pool's only liquidity");
        // only the reconcile trades in the new pool, so any move off the initial price proves it ran
        (uint160 sqrtAfter,,,) = manager.getSlot0(newKey.toId());
        assertTrue(sqrtAfter != SQRT_PRICE_1_1, "reconcile swap ran");
        assertApproxEqRel(sqrtAfter, SQRT_PRICE_1_1, 0.005e18, "small drift from the initial price");

        (uint160 routeSpAfter,,,) = manager.getSlot0(routeKey.toId());
        assertGt(routeSpAfter, routeSpBefore, "UR route did not raise routeKey sqrtPrice");

        uint256 dust0 = currency0.balanceOf(address(this)) - c0Before;
        uint256 dust1 = currency1.balanceOf(address(this)) + amount1In - c1Before;
        assertLt(dust0 + dust1, amount1In / 10_000, "dust under 1 bp of the budget");
        assertEq(currency0.balanceOf(address(zap)), 0, "zap token0 == 0");
        assertEq(currency1.balanceOf(address(zap)), 0, "zap token1 == 0");
    }

    /// @notice A front-runner initializes the pool at another price first. The route's allow-revert
    ///         initialize becomes a no-op, and the band rejects sizing at the front-run price.
    function test_add_uninitializedPool_frontRunInit_revertsOutOfBand() public {
        PoolKey memory newKey = _freshKey();
        manager.initialize(newKey, SQRT_PRICE_2_1);

        bytes memory route = _initAndSwapRoute(newKey, SQRT_PRICE_1_1, routeKey, false, 4.9e18, currency1, currency0);
        ISwapAndAdd.AddParams memory p = _bandedAddParams(newKey, 10e18, route);

        vm.expectRevert(
            abi.encodeWithSelector(
                ISwapAndAdd.PriceOutOfBand.selector, SQRT_PRICE_2_1, p.sqrtPriceMinX96, p.sqrtPriceMaxX96
            )
        );
        zap.add(p);
    }

    /// @notice Rebalance whose surplus -> deficit swap runs through the real UR within the unlock. The new
    ///         range sits above the current price, so the new position is single-sided token0.
    function test_rebalance_viaURRoute() public {
        // seed a position to rebalance (empty-route single-token1 add)
        ISwapAndAdd.AddParams memory ap = ISwapAndAdd.AddParams({
            poolKey: key,
            tickLower: TICK_LOWER,
            tickUpper: TICK_UPPER,
            amount0In: 0,
            amount1In: 10e18,
            route: "",
            routeFunding: new ISwapAndAdd.TokenAmount[](0),
            minLiquidity: 0,
            sqrtPriceMinX96: 0,
            sqrtPriceMaxX96: type(uint160).max,
            recipient: address(this),
            hookData: "",
            deadline: block.timestamp + 1
        });
        (uint256 tokenId,,,) = zap.add(ap);
        IERC721(address(lpm)).setApprovalForAll(address(zap), true);

        (uint160 routeSpBefore,,,) = manager.getSlot0(routeKey.toId());
        // bulk token1 -> token0 via UR on routeKey (within the zap's unlock of `key`)
        bytes memory route = _v4SwapRoute(routeKey, false, 1e18, currency1, currency0);

        ISwapAndAdd.RebalanceParams memory rp = ISwapAndAdd.RebalanceParams({
            tokenId: tokenId,
            additional0: 0, // full move: redeploy everything, add/return nothing
            additional1: 0,
            newTickLower: 600, // above current tick (0) -> single-sided token0
            newTickUpper: 1800,
            route: route,
            routeFunding: new ISwapAndAdd.TokenAmount[](0),
            minLiquidity: 0,
            sqrtPriceMinX96: 0,
            sqrtPriceMaxX96: type(uint160).max,
            recipient: address(this),
            hookData: "",
            deadline: block.timestamp + 1
        });

        (uint256 newTokenId, uint128 newLiq,,) = zap.rebalance(rp);

        assertEq(IERC721(address(lpm)).ownerOf(newTokenId), address(this), "user owns new NFT");
        assertGt(newLiq, 0, "new liquidity minted");
        assertEq(lpm.getPositionLiquidity(tokenId), 0, "old position emptied");
        assertEq(currency0.balanceOf(address(zap)), 0, "zap token0 == 0");
        assertEq(currency1.balanceOf(address(zap)), 0, "zap token1 == 0");

        // proof the UR route executed on routeKey (touched only by the route leg)
        (uint160 routeSpAfter,,,) = manager.getSlot0(routeKey.toId());
        assertGt(routeSpAfter, routeSpBefore, "UR route did not raise routeKey sqrtPrice");
    }

    /// @notice Compound whose fee-balancing swap runs through the real UR within the unlock. The same
    ///         tokenId grows in place.
    function test_compound_viaURRoute() public {
        ISwapAndAdd.AddParams memory ap = ISwapAndAdd.AddParams({
            poolKey: key,
            tickLower: TICK_LOWER,
            tickUpper: TICK_UPPER,
            amount0In: 0,
            amount1In: 10e18,
            route: "",
            routeFunding: new ISwapAndAdd.TokenAmount[](0),
            minLiquidity: 0,
            sqrtPriceMinX96: 0,
            sqrtPriceMaxX96: type(uint160).max,
            recipient: address(this),
            hookData: "",
            deadline: block.timestamp + 1
        });
        (uint256 tokenId, uint128 liq0,,) = zap.add(ap);
        IERC721(address(lpm)).setApprovalForAll(address(zap), true);
        // accrue fees on `key` with balanced round-trip swaps
        for (uint256 i = 0; i < 5; i++) {
            swap(key, true, -50e18, "");
            swap(key, false, -50e18, "");
        }

        ISwapAndAdd.CompoundParams memory p = ISwapAndAdd.CompoundParams({
            tokenId: tokenId,
            route: "",
            minLiquidityAdded: 0,
            sqrtPriceMinX96: 0,
            sqrtPriceMaxX96: type(uint160).max,
            recipient: address(this),
            hookData: "",
            deadline: block.timestamp + 1
        });
        // dry-run to size the route input
        uint256 snap = vm.snapshotState();
        (,, uint256 a1Base) = zap.compound(p);
        vm.revertToState(snap);

        (uint160 routeSpBefore,,,) = manager.getSlot0(routeKey.toId());
        p.route = _v4SwapRoute(routeKey, false, uint128(a1Base / 2), currency1, currency0);

        (uint128 added,,) = zap.compound(p);

        assertGt(added, 0, "fees compounded");
        assertEq(lpm.getPositionLiquidity(tokenId), liq0 + added, "same position grew by exactly added");
        assertEq(IERC721(address(lpm)).ownerOf(tokenId), address(this), "NFT never moved");
        assertEq(currency0.balanceOf(address(zap)), 0, "zap token0 == 0");
        assertEq(currency1.balanceOf(address(zap)), 0, "zap token1 == 0");

        // proof the UR route executed on routeKey (touched only by the route leg)
        (uint160 routeSpAfter,,,) = manager.getSlot0(routeKey.toId());
        assertGt(routeSpAfter, routeSpBefore, "UR route did not raise routeKey sqrtPrice");
    }

    /// @dev Regression: debt a subscriber plants on the router during fee collection must not reach the route.
    function test_increase_subscriberPlantsRouterDebt_reverts() public {
        ISwapAndAdd.AddParams memory ap = ISwapAndAdd.AddParams({
            poolKey: key,
            tickLower: TICK_LOWER,
            tickUpper: TICK_UPPER,
            amount0In: 10e18,
            amount1In: 10e18,
            route: "",
            routeFunding: new ISwapAndAdd.TokenAmount[](0),
            minLiquidity: 0,
            sqrtPriceMinX96: 0,
            sqrtPriceMaxX96: type(uint160).max,
            recipient: address(this),
            hookData: "",
            deadline: block.timestamp + 1
        });
        (uint256 tokenId,,,) = zap.add(ap);
        IERC721(address(lpm)).setApprovalForAll(address(zap), true);

        // the subscriber takes token1 on the router's tab when the fees are collected
        MockRouterDebtSubscriber subscriber = new MockRouterDebtSubscriber();
        lpm.subscribe(tokenId, address(subscriber), "");
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = Planner.init().add(Actions.TAKE, abi.encode(currency1, ActionConstants.MSG_SENDER, 1e18)).encode();
        subscriber.arm(
            IUniversalRouter(address(router)), abi.encode(abi.encodePacked(bytes1(uint8(Commands.V4_SWAP))), inputs)
        );

        vm.expectRevert(ISwapAndAdd.UnsettledDeltas.selector);
        zap.increase(
            ISwapAndAdd.IncreaseParams({
                tokenId: tokenId,
                amount0In: 0,
                amount1In: 5e18,
                route: _v4SwapRoute(routeKey, false, 1e18, currency1, currency0),
                routeFunding: new ISwapAndAdd.TokenAmount[](0),
                minLiquidityAdded: 0,
                sqrtPriceMinX96: 0,
                sqrtPriceMaxX96: type(uint160).max,
                recipient: address(this),
                hookData: "",
                deadline: block.timestamp + 1
            })
        );
    }
}
