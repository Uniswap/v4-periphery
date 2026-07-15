// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {IERC721} from "forge-std/interfaces/IERC721.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {Plan, Planner} from "../test/shared/Planner.sol";
import {PathKey} from "../src/libraries/PathKey.sol";
import {Actions} from "../src/libraries/Actions.sol";
import {ActionConstants} from "../src/libraries/ActionConstants.sol";
import {IV4Router} from "../src/interfaces/IV4Router.sol";
import {IPositionManager} from "../src/interfaces/IPositionManager.sol";
import {ISwapAndAdd} from "../src/interfaces/ISwapAndAdd.sol";
import {IUniversalRouter} from "../src/interfaces/external/IUniversalRouter.sol";

import {Commands} from "universal-router/contracts/libraries/Commands.sol";

/// @notice Sepolia-FORK integration against the LIVE deployment — nothing is deployed here except the test
///         pool's mock tokens; the zap and its patched Universal Router are the actual onchain bytecode
///         (broadcast @ block 11276910, script/DeploySwapAndAdd.s.sol). Pools are created fresh in the fork
///         and seeded through the zap itself (first-LP on an empty pool is a supported flow), so the tests
///         are deterministic and independent of whatever thin liquidity Sepolia happens to have.
///         Run: FOUNDRY_PROFILE=integration forge test --match-contract SwapAndAddForkSepoliaTest
contract SwapAndAddForkSepoliaTest is Test {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    // ── live Sepolia deployment (chore(SwapAndAdd): deploy zap + patched UR to Sepolia) ──
    address constant ZAP = 0xc6b69cbB1f9EB78D15C3876105B9EDA458CB404F;
    address constant UR = 0x44518461733Fd7f5DC5996facB405CF659108Ea2;
    // ── canonical Sepolia protocol addresses (verified in script/DeploySwapAndAdd.s.sol) ──
    address constant POOL_MANAGER = 0xE03A1074c86CFeDd5C142C4F04F1a1536e203543;
    address constant POSM = 0x429ba70129df741B2Ca2a85BC3A2a3328e5c09b4;
    address constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    uint160 constant SQRT_PRICE_1_1 = 79228162514264337593543950336;
    int24 constant TICK_LOWER = -600;
    int24 constant TICK_UPPER = 600;

    IPoolManager manager = IPoolManager(POOL_MANAGER);
    IPositionManager posm = IPositionManager(POSM);
    IAllowanceTransfer permit2 = IAllowanceTransfer(PERMIT2);
    ISwapAndAdd zap = ISwapAndAdd(ZAP);

    MockERC20 tokenA;
    MockERC20 tokenB;
    PoolKey key; // tokenA/tokenB, sorted
    PoolKey nativeKey; // ETH/tokenB

    function setUp() public {
        uint256 forkBlock = vm.envOr("SEPOLIA_FORK_BLOCK", uint256(0));
        string memory forkUrl = vm.envOr("SEPOLIA_FORK_URL", string("https://ethereum-sepolia-rpc.publicnode.com"));
        if (forkBlock == 0) vm.createSelectFork(forkUrl);
        else vm.createSelectFork(forkUrl, forkBlock);

        MockERC20 x = new MockERC20("TestA", "TSTA", 18);
        MockERC20 y = new MockERC20("TestB", "TSTB", 18);
        (tokenA, tokenB) = address(x) < address(y) ? (x, y) : (y, x);
        tokenA.mint(address(this), 1_000_000e18);
        tokenB.mint(address(this), 1_000_000e18);
        _wireToken(address(tokenA));
        _wireToken(address(tokenB));
        vm.deal(address(this), 1_000 ether);

        key = PoolKey({
            currency0: Currency.wrap(address(tokenA)),
            currency1: Currency.wrap(address(tokenB)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });
        manager.initialize(key, SQRT_PRICE_1_1);
        nativeKey = PoolKey({
            currency0: CurrencyLibrary.ADDRESS_ZERO,
            currency1: Currency.wrap(address(tokenB)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });
        manager.initialize(nativeKey, SQRT_PRICE_1_1);
    }

    function _wireToken(address t) internal {
        MockERC20(t).approve(PERMIT2, type(uint256).max);
        permit2.approve(t, ZAP, type(uint160).max, type(uint48).max);
        permit2.approve(t, UR, type(uint160).max, type(uint48).max); // for the fee-generating direct UR swap
    }

    function _addParams(PoolKey memory k, uint256 a0, uint256 a1, bytes memory route)
        internal
        view
        returns (ISwapAndAdd.AddParams memory)
    {
        return ISwapAndAdd.AddParams({
            poolKey: k,
            tickLower: TICK_LOWER,
            tickUpper: TICK_UPPER,
            amount0In: a0,
            amount1In: a1,
            route: route,
            minLiquidity: 0,
            recipient: address(this),
            hookData: "",
            deadline: block.timestamp + 1
        });
    }

    /// @dev first LP through the live zap itself: two-sided in-ratio on the empty pool.
    function _seed(PoolKey memory k) internal returns (uint256 tokenId, uint128 liq) {
        uint256 v = Currency.unwrap(k.currency0) == address(0) ? 50e18 : 0;
        (tokenId, liq,,) = zap.add{value: v}(_addParams(k, 50e18, 50e18, ""));
    }

    // ─────────────────────────── live-bytecode behavior, no route ───────────────────────────

    function test_forkSepolia_add_firstLiquidity_emptyPool() public {
        (uint256 tokenId, uint128 liq) = _seed(key);
        assertEq(IERC721(POSM).ownerOf(tokenId), address(this), "user owns NFT");
        assertGt(liq, 0, "liquidity minted on live contracts");
        assertEq(tokenA.balanceOf(ZAP), 0, "zap token0 == 0");
        assertEq(tokenB.balanceOf(ZAP), 0, "zap token1 == 0");
    }

    function test_forkSepolia_add_singleSided_reconciles() public {
        _seed(key);
        (uint256 tokenId, uint128 liq, uint256 a0, uint256 a1) = zap.add(_addParams(key, 0, 10e18, ""));
        assertEq(IERC721(POSM).ownerOf(tokenId), address(this), "user owns NFT");
        assertGt(liq, 0, "liquidity minted");
        assertGt(a0, 0, "token0 side funded by the same-pool reconcile");
        assertGt(a1, 0, "token1 deployed");
        assertEq(tokenA.balanceOf(ZAP), 0, "zap token0 == 0");
        assertEq(tokenB.balanceOf(ZAP), 0, "zap token1 == 0");
    }

    function test_forkSepolia_add_native_singleSided() public {
        _seed(nativeKey);
        (uint256 tokenId, uint128 liq,,) = zap.add{value: 5 ether}(_addParams(nativeKey, 5 ether, 0, ""));
        assertEq(IERC721(POSM).ownerOf(tokenId), address(this), "user owns NFT");
        assertGt(liq, 0, "liquidity minted from native budget");
        assertEq(ZAP.balance, 0, "zap eth == 0");
        assertEq(tokenB.balanceOf(ZAP), 0, "zap token == 0");
    }

    // ─────────────────────────── routed: V4_SWAP inside the zap's unlock, on the LIVE patched UR ───────────────

    /// @dev The single most important live assertion: the deployed UR accepts V4_SWAP within the zap's
    ///      already-open unlock (the canonical UR reverts AlreadyUnlocked here).
    function test_forkSepolia_add_viaLiveURRoute() public {
        _seed(key);
        bytes memory route = _v4SwapRoute(key, false, 4e18, key.currency1, key.currency0);
        (uint256 tokenId, uint128 liq,,) = zap.add(_addParams(key, 0, 10e18, route));
        assertEq(IERC721(POSM).ownerOf(tokenId), address(this), "user owns NFT");
        assertGt(liq, 0, "liquidity minted through the live UR route");
        assertEq(tokenA.balanceOf(ZAP), 0, "zap token0 == 0");
        assertEq(tokenB.balanceOf(ZAP), 0, "zap token1 == 0");
    }

    // ─────────────────────────── rebalance + compound on live bytecode ───────────────────────────

    function test_forkSepolia_rebalance_full() public {
        (uint256 tokenId,,,) = zap.add(_addParams(key, 50e18, 50e18, ""));
        IERC721(POSM).setApprovalForAll(ZAP, true);

        ISwapAndAdd.RebalanceParams memory p = ISwapAndAdd.RebalanceParams({
            tokenId: tokenId,
            additionalA: 0,
            additionalB: 0,
            newTickLower: TICK_LOWER - 600,
            newTickUpper: TICK_UPPER + 600,
            route: "",
            minLiquidity: 0,
            recipient: address(this),
            hookData: "",
            deadline: block.timestamp + 1
        });
        (uint256 newTokenId, uint128 newLiq,,) = zap.rebalance(p);

        assertEq(IERC721(POSM).ownerOf(newTokenId), address(this), "user owns new NFT");
        assertGt(newLiq, 0, "new liquidity minted");
        assertEq(posm.getPositionLiquidity(tokenId), 0, "old position fully burned");
        assertEq(tokenA.balanceOf(ZAP), 0, "zap token0 == 0");
        assertEq(tokenB.balanceOf(ZAP), 0, "zap token1 == 0");
    }

    function test_forkSepolia_compound_afterRealSwapFees() public {
        (uint256 tokenId,,) = _seedAndEarnFees();
        IERC721(POSM).setApprovalForAll(ZAP, true);

        ISwapAndAdd.CompoundParams memory p = ISwapAndAdd.CompoundParams({
            tokenId: tokenId,
            route: "",
            minLiquidityAdded: 0,
            recipient: address(this),
            hookData: "",
            deadline: block.timestamp + 1
        });
        (uint128 liqAdded,,) = zap.compound(p);

        assertGt(liqAdded, 0, "fees compounded into the live position");
        assertEq(tokenA.balanceOf(ZAP), 0, "zap token0 == 0");
        assertEq(tokenB.balanceOf(ZAP), 0, "zap token1 == 0");
    }

    /// @dev seed, then generate real fees with a round-trip swap executed directly on the LIVE UR (standalone
    ///      mode: it opens its own unlock) — also covers the deployed router's plain-swap path.
    function _seedAndEarnFees() internal returns (uint256 tokenId, uint128 liq, uint256 feesSwapped) {
        (tokenId, liq) = _seed(key);
        (bytes memory c1, bytes[] memory i1) =
            _decodeRoute(_v4SwapRoute(key, false, 10e18, key.currency1, key.currency0));
        IUniversalRouter(UR).execute(c1, i1);
        (bytes memory c2, bytes[] memory i2) = _decodeRoute(_v4SwapRoute(key, true, 9e18, key.currency0, key.currency1));
        IUniversalRouter(UR).execute(c2, i2);
        feesSwapped = 19e18;
    }

    function _decodeRoute(bytes memory route) internal pure returns (bytes memory, bytes[] memory) {
        return abi.decode(route, (bytes, bytes[]));
    }

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
        plan = plan.add(Actions.SETTLE, abi.encode(inCcy, ActionConstants.OPEN_DELTA, true));
        plan = plan.add(Actions.TAKE, abi.encode(outCcy, ActionConstants.MSG_SENDER, ActionConstants.OPEN_DELTA));
        bytes memory commands = abi.encodePacked(bytes1(uint8(Commands.V4_SWAP)));
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = plan.encode();
        return abi.encode(commands, inputs);
    }

    // ── real Trading API route fixture ──
    // Fetched 2026-07-15 with swapper = the LIVE zap: 50e6 USDC -> WETH through the real, TAPI-indexed
    // v4 USDC/WETH 0.01%/60 pool. Bytes are the verbatim /v1/swap "data" tail (selector stripped):
    // abi.encode(commands, inputs, deadline). Pinned to the block the quote priced against, so the route's
    // own amountOutMinimum stays satisfiable forever. Refresh via script/fetch-tapi-route.sh.
    address constant USDC = 0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238;
    address constant WETH = 0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14;
    uint256 constant TAPI_FIXTURE_BLOCK = 11277038;
    bytes constant TAPI_EXECUTE_TAIL =
        hex"000000000000000000000000000000000000000000000000000000000000006000000000000000000000000000000000000000000000000000000000000000a0000000000000000000000000000000000000000000000000000000006a575f80000000000000000000000000000000000000000000000000000000000000000110000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000001000000000000000000000000000000000000000000000000000000000000002000000000000000000000000000000000000000000000000000000000000003c0000000000000000000000000000000000000000000000000000000000000004000000000000000000000000000000000000000000000000000000000000000800000000000000000000000000000000000000000000000000000000000000003070b0e000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000030000000000000000000000000000000000000000000000000000000000000060000000000000000000000000000000000000000000000000000000000000022000000000000000000000000000000000000000000000000000000000000002a000000000000000000000000000000000000000000000000000000000000001a000000000000000000000000000000000000000000000000000000000000000200000000000000000000000001c7d4b196cb0c7b01d743fbc6116a902379c723800000000000000000000000000000000000000000000000000000000000000800000000000000000000000000000000000000000000000000000000002faf080000000000000000000000000000000000000000000000000006d466f6d8e5ae700000000000000000000000000000000000000000000000000000000000000010000000000000000000000000000000000000000000000000000000000000020000000000000000000000000fff9976782d46cc05630d1f6ebab18b2324d6b140000000000000000000000000000000000000000000000000000000000000064000000000000000000000000000000000000000000000000000000000000003c000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000a0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000600000000000000000000000001c7d4b196cb0c7b01d743fbc6116a902379c7238000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000010000000000000000000000000000000000000000000000000000000000000060000000000000000000000000fff9976782d46cc05630d1f6ebab18b2324d6b14000000000000000000000000c6b69cbb1f9eb78d15c3876105b9eda458cb404f0000000000000000000000000000000000000000000000000000000000000000756e69780000d7ff01b6";

    /// @dev The full production flow with real TAPI calldata: route executed by the live zap on the live
    ///      patched UR, deploying into the real v4 pool the route also swaps through.
    ///
    ///      KNOWN INCOMPATIBILITY (pinned here on purpose): v4-periphery MAIN carries an unreleased ABI
    ///      change — `minHopPriceX36` (per-hop price limits) in every IV4Router swap-param struct. Any router
    ///      built from head (like this deployment's UR: UR-main + the unlock fix, same periphery pin as
    ///      UR-main) therefore rejects TAPI's v4 action encoding, which targets the DEPLOYED canonical UR
    ///      built from an older periphery release (v2/v3 legs are command-level and unaffected). The gap
    ///      closes when the next canonical UR release and TAPI roll out the new ABI together;
    ///      `_transcodeTapiV4Actions` (canonical -> head encoding, hop price limits zeroed) bridges until
    ///      then and must be deleted at that point. If this test starts failing to decode, the ABI drifted
    ///      again.
    function test_forkSepolia_add_viaRealTapiRoute() public {
        string memory forkUrl = vm.envOr("SEPOLIA_FORK_URL", string(""));
        vm.skip(bytes(forkUrl).length == 0); // pinned block needs archive state; skip on public RPC
        vm.createSelectFork(forkUrl, TAPI_FIXTURE_BLOCK);

        (bytes memory commands, bytes[] memory inputs,) = abi.decode(TAPI_EXECUTE_TAIL, (bytes, bytes[], uint256));
        inputs[0] = _transcodeTapiV4Actions(inputs[0]);
        bytes memory route = abi.encode(commands, inputs); // the zap has its own deadline param

        deal(USDC, address(this), 100e6);
        MockERC20(USDC).approve(PERMIT2, type(uint256).max);
        permit2.approve(USDC, ZAP, type(uint160).max, type(uint48).max);

        PoolKey memory k = PoolKey({
            currency0: Currency.wrap(USDC),
            currency1: Currency.wrap(WETH),
            fee: 100,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });
        (, int24 tick,,) = manager.getSlot0(k.toId());
        int24 lo = (tick / 60) * 60 - 20 * 60;
        int24 hi = (tick / 60) * 60 + 20 * 60;

        ISwapAndAdd.AddParams memory p = _addParams(k, 100e6, 0, route);
        p.tickLower = lo;
        p.tickUpper = hi;
        (uint256 tokenId, uint128 liq,,) = zap.add(p);

        assertEq(IERC721(POSM).ownerOf(tokenId), address(this), "user owns NFT");
        assertGt(liq, 0, "TAPI-routed budget deployed into the real v4 pool");
        assertEq(MockERC20(USDC).balanceOf(ZAP), 0, "zap usdc == 0");
        assertEq(MockERC20(WETH).balanceOf(ZAP), 0, "zap weth == 0");
    }

    /// @dev TAPI's canonical multi-hop exact-input shape (no minHopPriceX36) — decode-only.
    struct CanonicalExactInputParams {
        Currency currencyIn;
        PathKey[] path;
        uint128 amountIn;
        uint128 amountOutMinimum;
    }

    /// @dev Canonical -> branch v4-action re-encoding; reverts on any action this fixture doesn't carry so a
    ///      refreshed fixture with new action types fails loudly instead of passing through untranscoded.
    function _transcodeTapiV4Actions(bytes memory input) internal pure returns (bytes memory) {
        (bytes memory actions, bytes[] memory params) = abi.decode(input, (bytes, bytes[]));
        Plan memory plan = Planner.init();
        for (uint256 i; i < actions.length; i++) {
            uint8 action = uint8(actions[i]);
            if (action == uint8(Actions.SWAP_EXACT_IN)) {
                CanonicalExactInputParams memory c = abi.decode(params[i], (CanonicalExactInputParams));
                IV4Router.ExactInputParams memory b = IV4Router.ExactInputParams({
                    currencyIn: c.currencyIn,
                    path: c.path,
                    minHopPriceX36: new uint256[](c.path.length),
                    amountIn: c.amountIn,
                    amountOutMinimum: c.amountOutMinimum
                });
                plan = plan.add(Actions.SWAP_EXACT_IN, abi.encode(b));
            } else if (action == uint8(Actions.SETTLE) || action == uint8(Actions.TAKE)) {
                plan = plan.add(action, params[i]); // shape-identical on both ABIs
            } else {
                revert("transcoder: unhandled TAPI action - extend before trusting the result");
            }
        }
        return plan.encode();
    }

    receive() external payable {}
}
