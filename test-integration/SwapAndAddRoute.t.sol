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

// Build the route bytes with THIS repo's own v4-periphery libraries. They are byte-identical to the copy UR
// decodes against (verified: same Actions opcodes + same IV4Router.ExactInputSingleParams layout).
import {Plan, Planner} from "../test/shared/Planner.sol";
import {Actions} from "../src/libraries/Actions.sol";
import {ActionConstants} from "../src/libraries/ActionConstants.sol";
import {IV4Router} from "../src/interfaces/IV4Router.sol";

import {PosmTestSetup} from "../test/shared/PosmTestSetup.sol";
import {SwapAndAdd} from "../src/SwapAndAdd.sol";
import {ISwapAndAdd} from "../src/interfaces/ISwapAndAdd.sol";
import {IUniversalRouter} from "../src/interfaces/external/IUniversalRouter.sol";

import {UniversalRouter} from "universal-router/contracts/UniversalRouter.sol";
import {RouterParameters} from "universal-router/contracts/types/RouterParameters.sol";
import {Commands} from "universal-router/contracts/libraries/Commands.sol";

/// @notice Integration test: SwapAndAdd's non-empty `route` path executed through the REAL modified Universal
///         Router, with UR.execute called from inside the zap's own v4 PoolManager unlock. This is the path
///         the UR change (`feat/v4-swap-within-existing-unlock`, V4_SWAP via _executeActionsWithoutUnlock)
///         exists to enable — if UR lacked that branch, the nested execute would revert AlreadyUnlocked.
contract SwapAndAddRouteTest is PosmTestSetup {
    using StateLibrary for IPoolManager;
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;

    SwapAndAdd zap;
    UniversalRouter router;
    PoolKey routeKey; // a SECOND pool, only ever touched by the UR route leg — isolates the proof.

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

        // the REAL modified Universal Router, pointed at this test's PoolManager + Permit2 (v2/v3/migration off)
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

    /// @dev builds a verbatim UR route: exact-in `inCcy`->`outCcy` on `poolKey` as a single V4_SWAP, settling
    ///      the input from the caller (the zap) via Permit2 and taking the output back to the caller (the zap).
    function _v4SwapRoute(PoolKey memory poolKey, bool zeroForOne, uint128 amtIn, Currency inCcy, Currency outCcy)
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

        bytes memory commands = abi.encodePacked(bytes1(uint8(Commands.V4_SWAP)));
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = plan.encode();
        return abi.encode(commands, inputs);
    }

    /// @notice Single-token1 budget; the bulk token1->token0 swap runs through the real UR (on `routeKey`,
    ///         within the zap's unlock of `key`), and the same-pool reconcile finishes the position.
    function test_add_singleToken1_viaURRoute() public {
        uint256 amount1In = 10e18;
        uint128 routeAmountIn = 3e18; // sell 3e18 token1 -> token0 on routeKey via UR; reconcile tops up the rest
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
            minLiquidity: 0,
            recipient: address(this),
            hookData: "",
            deadline: block.timestamp + 1
        });

        (uint256 tokenId, uint128 liq, uint256 a0, uint256 a1) = zap.add(p);

        assertEq(IERC721(address(lpm)).ownerOf(tokenId), address(this), "user owns NFT");
        assertGt(liq, 0, "liquidity minted");
        assertGt(a0, 0, "token0 deployed");
        assertGt(a1, 0, "token1 deployed");
        // no meaningful dust of the swapped-into token (token0) returned to the user
        assertApproxEqAbs(currency0.balanceOf(address(this)), c0Before, 5, "no token0 dust to user");
        // contract strands nothing
        assertEq(currency0.balanceOf(address(zap)), 0, "zap token0 == 0");
        assertEq(currency1.balanceOf(address(zap)), 0, "zap token1 == 0");

        // Proof the UR route executed: routeKey is touched ONLY by the route leg, so its price moving means the
        // real UR ran a V4_SWAP within the zap's unlock. (A same-pool-only fallback would leave routeKey at 1:1.)
        (uint160 routeSpAfter,,,) = manager.getSlot0(routeKey.toId());
        assertTrue(routeSpAfter != routeSpBefore, "UR route did not execute on the route pool");
        // selling token1 -> token0 (oneForZero) adds token1 / removes token0, so sqrtPrice (~sqrt(token1/token0)) rises
        assertGt(routeSpAfter, routeSpBefore, "selling token1 should raise routeKey's sqrtPrice");
    }

    /// @notice Native-input route that consumes only PART of the forwarded value: the route encodes a fixed
    ///         2-ether input while the zap forwards its whole 10-ether native balance. The unconsumed 8 ether
    ///         must be reclaimed from UR (UR's balance is permissionlessly sweepable — anything left there is
    ///         lost) and put back through the same-pool reconcile instead.
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
            minLiquidity: 0,
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

    /// @notice Rebalance whose surplus->deficit leg runs through the real UR within the unlock. The new range is
    ///         entirely ABOVE the current price, so the new position is single-sided token0 (deficit = token0,
    ///         surplus = token1) -> the bulk token1->token0 swap routes via UR on routeKey, reconcile finishes.
    function test_rebalance_viaURRoute() public {
        // seed a position to rebalance (empty-route single-token1 add)
        ISwapAndAdd.AddParams memory ap = ISwapAndAdd.AddParams({
            poolKey: key,
            tickLower: TICK_LOWER,
            tickUpper: TICK_UPPER,
            amount0In: 0,
            amount1In: 10e18,
            route: "",
            minLiquidity: 0,
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
            additionalA: 0, // full move: redeploy everything, add/return nothing
            additionalB: 0,
            newTickLower: 600, // above current tick (0) -> single-sided token0
            newTickUpper: 1800,
            route: route,
            minLiquidity: 0,
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

    /// @notice Compound whose fee-balancing leg runs through the real UR within the unlock: the collected fees
    ///         are routed token1->token0 on routeKey, the same-pool reconcile finishes, and the SAME tokenId
    ///         grows in place. Also the only existing-tokenId path exercising the nested UR execute.
    function test_compound_viaURRoute() public {
        ISwapAndAdd.AddParams memory ap = ISwapAndAdd.AddParams({
            poolKey: key,
            tickLower: TICK_LOWER,
            tickUpper: TICK_UPPER,
            amount0In: 0,
            amount1In: 10e18,
            route: "",
            minLiquidity: 0,
            recipient: address(this),
            hookData: "",
            deadline: block.timestamp + 1
        });
        (uint256 tokenId, uint128 liq0,,) = zap.add(ap);
        IERC721(address(lpm)).setApprovalForAll(address(zap), true);
        // accrue fees on `key`: balanced round-trips so the price returns near 1:1 and both sides collect
        for (uint256 i = 0; i < 5; i++) {
            swap(key, true, -50e18, "");
            swap(key, false, -50e18, "");
        }

        ISwapAndAdd.CompoundParams memory p = ISwapAndAdd.CompoundParams({
            tokenId: tokenId,
            route: "",
            minLiquidityAdded: 0,
            recipient: address(this),
            hookData: "",
            deadline: block.timestamp + 1
        });
        // dry-run (the onchain stand-in for quoting the unclaimed fees offchain) to size the route input
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
}
