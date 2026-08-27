// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {FixedPoint96} from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {IERC721} from "forge-std/interfaces/IERC721.sol";

import {PosmTestSetup} from "./shared/PosmTestSetup.sol";
import {MockSwapRoute} from "./mocks/MockSwapRoute.sol";
import {ISwapAndAdd} from "../src/interfaces/ISwapAndAdd.sol";
import {IUniversalRouter} from "../src/interfaces/external/IUniversalRouter.sol";

/// @notice Gas snapshots for every SwapAndAdd operation under its meaningful execution conditions. The
///         dimensions that dominate cost: whether the reconcile swap runs (single-sided vs balanced input),
///         whether a route executes before sizing, native vs ERC-20 currency0, and whether accrued fees are
///         collected (grow ops). Numbers land in snapshots/SwapAndAddGasTest.json via the CI isolate run.
contract SwapAndAddGasTest is PosmTestSetup {
    using CurrencyLibrary for Currency;

    ISwapAndAdd zap;
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
        // Same artifact-based deployment as SwapAndAdd.t.sol (via_ir=true/500 production build).
        zap = ISwapAndAdd(
            deployCode("SwapAndAdd.sol:SwapAndAdd", abi.encode(manager, permit2, lpm, IUniversalRouter(address(route))))
        );
        MockERC20(Currency.unwrap(currency0)).mint(address(route), 1_000_000e18);
        MockERC20(Currency.unwrap(currency1)).mint(address(route), 1_000_000e18);

        seedBalance(address(this));
        _approveZap(currency0);
        _approveZap(currency1);

        vm.deal(address(this), 1_000 ether);
        (nativeKey,) = initPoolAndAddLiquidityETH(
            CurrencyLibrary.ADDRESS_ZERO, currency1, IHooks(address(0)), 3000, SQRT_PRICE_1_1, 1 ether
        );
        modifyLiquidityRouter.modifyLiquidity{value: 50 ether}(
            nativeKey,
            ModifyLiquidityParams({tickLower: -600, tickUpper: 600, liquidityDelta: int256(uint256(200e18)), salt: 0}),
            ""
        );

        IERC721(address(lpm)).setApprovalForAll(address(zap), true);
    }

    function _approveZap(Currency c) internal {
        MockERC20(Currency.unwrap(c)).approve(address(permit2), type(uint256).max);
        permit2.approve(Currency.unwrap(c), address(zap), type(uint160).max, type(uint48).max);
    }

    function _addParams(uint256 amount0In, uint256 amount1In) internal view returns (ISwapAndAdd.AddParams memory) {
        return ISwapAndAdd.AddParams({
            poolKey: key,
            tickLower: TICK_LOWER,
            tickUpper: TICK_UPPER,
            amount0In: amount0In,
            amount1In: amount1In,
            route: "",
            routeFunding: new ISwapAndAdd.TokenAmount[](0),
            minLiquidity: 0,
            recipient: address(this),
            hookData: "",
            deadline: block.timestamp + 1
        });
    }

    function _increaseParams(uint256 tokenId, uint256 amount0In, uint256 amount1In)
        internal
        view
        returns (ISwapAndAdd.IncreaseParams memory)
    {
        return ISwapAndAdd.IncreaseParams({
            tokenId: tokenId,
            amount0In: amount0In,
            amount1In: amount1In,
            route: "",
            routeFunding: new ISwapAndAdd.TokenAmount[](0),
            minLiquidityAdded: 0,
            recipient: address(this),
            hookData: "",
            deadline: block.timestamp + 1
        });
    }

    /// @dev Balanced round-trip swaps: both sides of in-range liquidity accrue fees, price returns near 1:1.
    function _generateFees() internal {
        for (uint256 i = 0; i < 5; i++) {
            swap(key, true, -50e18, "");
            swap(key, false, -50e18, "");
        }
    }

    // ───────────────────────────────────────────── add ─────────────────────────────────────────────

    /// @dev The full path: fee-aware sizing, flash-take, mint, reconcile swap, trim, sweep.
    function test_gas_add_singleSided() public {
        zap.add(_addParams(0, 10e18));
        vm.snapshotGasLastCall("SwapAndAdd_add_singleSided");
    }

    /// @dev Proportional input at 1:1 — the reconcile swap is skipped (wei-scale residue at most).
    function test_gas_add_balanced() public {
        zap.add(_addParams(10e18, 10e18));
        vm.snapshotGasLastCall("SwapAndAdd_add_balanced");
    }

    /// @dev Skewed two-sided input: reconcile swap converts only the surplus share.
    function test_gas_add_mixedRatio() public {
        zap.add(_addParams(3e18, 10e18));
        vm.snapshotGasLastCall("SwapAndAdd_add_mixedRatio");
    }

    /// @dev Native currency0: value forwarding plus POSM's SWEEP refund leg.
    function test_gas_add_native() public {
        ISwapAndAdd.AddParams memory p = _addParams(1e17, 0);
        p.poolKey = nativeKey;
        zap.add{value: 1e17}(p);
        vm.snapshotGasLastCall("SwapAndAdd_add_native");
    }

    /// @dev Route-first: the mock converts half the token1 input to token0 at mid before sizing, so the
    ///      reconcile only closes the residual — measures the route plumbing on top of a near-balanced add.
    function test_gas_add_routed() public {
        route.config(Currency.unwrap(currency1), Currency.unwrap(currency0), FixedPoint96.Q96, 10000, 5e18, false);
        ISwapAndAdd.AddParams memory p = _addParams(0, 10e18);
        p.route = ROUTE_PAYLOAD;
        zap.add(p);
        vm.snapshotGasLastCall("SwapAndAdd_add_routed");
    }

    // ─────────────────────────────────────── increase / compound ───────────────────────────────────────

    /// @dev Warm position, no accrued fees: the fee-collect poke returns nothing.
    function test_gas_increase_noFees() public {
        (uint256 tokenId,,,) = zap.add(_addParams(0, 10e18));
        zap.increase(_increaseParams(tokenId, 0, 10e18));
        vm.snapshotGasLastCall("SwapAndAdd_increase_noFees");
    }

    /// @dev Accrued fees join the pulled budget: collect credits both tokens before sizing.
    function test_gas_increase_withAccruedFees() public {
        (uint256 tokenId,,,) = zap.add(_addParams(0, 10e18));
        _generateFees();
        zap.increase(_increaseParams(tokenId, 0, 10e18));
        vm.snapshotGasLastCall("SwapAndAdd_increase_withAccruedFees");
    }

    /// @dev Pure fee reinvestment: zero pulled budget, collected fees are the whole deploy.
    function test_gas_compound() public {
        (uint256 tokenId,,,) = zap.add(_addParams(0, 10e18));
        _generateFees();
        zap.compound(
            ISwapAndAdd.CompoundParams({
                tokenId: tokenId,
                route: "",
                minLiquidityAdded: 0,
                recipient: address(this),
                hookData: "",
                deadline: block.timestamp + 1
            })
        );
        vm.snapshotGasLastCall("SwapAndAdd_compound");
    }

    // ───────────────────────────────────────────── rebalance ─────────────────────────────────────────────

    /// @dev Burn old range, remint into a wider one: two POSM unlocks plus the full add path.
    function test_gas_rebalance() public {
        (uint256 tokenId,,,) = zap.add(_addParams(0, 10e18));
        zap.rebalance(
            ISwapAndAdd.RebalanceParams({
                tokenId: tokenId,
                additional0: 0,
                additional1: 0,
                newTickLower: -1200,
                newTickUpper: 1200,
                route: "",
                routeFunding: new ISwapAndAdd.TokenAmount[](0),
                minLiquidity: 0,
                recipient: address(this),
                hookData: "",
                deadline: block.timestamp + 1
            })
        );
        vm.snapshotGasLastCall("SwapAndAdd_rebalance");
    }
}
