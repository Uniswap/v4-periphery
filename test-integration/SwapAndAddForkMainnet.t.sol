// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {IERC721} from "forge-std/interfaces/IERC721.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {Plan, Planner} from "../test/shared/Planner.sol";
import {Actions} from "../src/libraries/Actions.sol";
import {ActionConstants} from "../src/libraries/ActionConstants.sol";
import {IV4Router} from "../src/interfaces/IV4Router.sol";
import {IPositionManager} from "../src/interfaces/IPositionManager.sol";
import {SwapAndAdd} from "../src/SwapAndAdd.sol";
import {ISwapAndAdd} from "../src/interfaces/ISwapAndAdd.sol";
import {IUniversalRouter} from "../src/interfaces/external/IUniversalRouter.sol";

import {UniversalRouter} from "universal-router/contracts/UniversalRouter.sol";
import {RouterParameters} from "universal-router/contracts/types/RouterParameters.sol";
import {Commands} from "universal-router/contracts/libraries/Commands.sol";

/// @notice Mainnet-FORK integration: deploys the REAL modified Universal Router + SwapAndAdd against the live
///         mainnet v4 PoolManager/POSM/Permit2 and drives an add against the real deep ETH/USDC pool
///         (id 0xdce6...78d). Backbone for the test suite and the eventual UI-on-anvil-fork.
///         Run: FOUNDRY_PROFILE=integration forge test --match-contract SwapAndAddForkMainnetTest
contract SwapAndAddForkMainnetTest is Test {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    // ── canonical mainnet addresses (from universal-router/script/deployParameters/DeployMainnet.s.sol) ──
    address constant POOL_MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    address constant POSM = 0xbD216513d74C8cf14cf4747E6AaA6420FF64ee9e;
    address constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address constant WETH9 = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant V2_FACTORY = 0x5C69bEe701ef814a2B6a3EDD4B1652CB9cc5aA6f;
    address constant V3_FACTORY = 0x1F98431c8aD98523631AE4a59f267346ea31F984;
    bytes32 constant PAIR_HASH = 0x96e8ac4277198ff8b6f785478aa9a39f403cb768dd02cbee326c3e7da348845f;
    bytes32 constant POOL_HASH = 0xe34f199b19b2b4f47f68442619d555527d244f78a3297ea89325f843f87b8b54;
    address constant V3_POSM = 0xC36442b4a4522E871399CD717aBDD847Ab11FE88;
    address constant SPOKE = 0x5c7BCd6E7De5423a257D81B442095A1a6ced35C5;

    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    bytes32 constant TARGET_ID = 0xdce6394339af00981949f5f3baf27e3610c76326a700af57e4b3e3ae4977f78d;

    IPoolManager manager = IPoolManager(POOL_MANAGER);
    IPositionManager posm = IPositionManager(POSM);
    IAllowanceTransfer permit2 = IAllowanceTransfer(PERMIT2);
    UniversalRouter router;
    SwapAndAdd zap;
    PoolKey key;

    function setUp() public {
        vm.createSelectFork(vm.envOr("FORK_URL", string("https://ethereum-rpc.publicnode.com")));

        key = _reconstructKey();
        emit log_named_uint("pool fee", key.fee);
        emit log_named_int("pool tickSpacing", key.tickSpacing);
        emit log_named_address("currency0", Currency.unwrap(key.currency0));
        emit log_named_address("currency1", Currency.unwrap(key.currency1));

        RouterParameters memory p = RouterParameters({
            permit2: PERMIT2,
            weth9: WETH9,
            v2Factory: V2_FACTORY,
            v3Factory: V3_FACTORY,
            pairInitCodeHash: PAIR_HASH,
            poolInitCodeHash: POOL_HASH,
            v4PoolManager: POOL_MANAGER,
            permissionsAdapterFactory: address(0),
            v3NFTPositionManager: V3_POSM,
            v4PositionManager: POSM,
            spokePool: SPOKE
        });
        router = new UniversalRouter(p);
        zap = new SwapAndAdd(manager, permit2, posm, IUniversalRouter(address(router)));
    }

    /// @dev brute-force the PoolKey whose id == TARGET_ID, assuming no hook. Tries native-ETH/USDC then USDC/WETH.
    function _reconstructKey() internal pure returns (PoolKey memory) {
        (bool ok, PoolKey memory k) = _tryPair(Currency.wrap(address(0)), Currency.wrap(USDC));
        if (ok) return k;
        (ok, k) = _tryPair(Currency.wrap(USDC), Currency.wrap(WETH9));
        if (ok) return k;
        revert("pool key not found with hooks=0 (pool may use a hook or non-standard fee/tickSpacing)");
    }

    function _tryPair(Currency c0, Currency c1) internal pure returns (bool, PoolKey memory) {
        uint24[7] memory fees = [uint24(100), 500, 3000, 10000, 500, 100, 3000];
        int24[7] memory tss = [int24(1), 10, 60, 200, 60, 10, 200];
        for (uint256 i; i < 7; i++) {
            PoolKey memory k = PoolKey(c0, c1, fees[i], tss[i], IHooks(address(0)));
            if (PoolId.unwrap(k.toId()) == TARGET_ID) return (true, k);
        }
        PoolKey memory empty;
        return (false, empty);
    }

    function _ticks() internal view returns (int24 lower, int24 upper) {
        (, int24 tick,,) = manager.getSlot0(key.toId());
        int24 ts = key.tickSpacing;
        int24 a = (tick / ts) * ts;
        lower = a - 20 * ts;
        upper = a + 20 * ts;
    }

    function _fundUsdc(uint256 amt) internal {
        deal(USDC, address(this), amt);
        IERC20(USDC).approve(PERMIT2, type(uint256).max);
        permit2.approve(USDC, address(zap), type(uint160).max, type(uint48).max);
    }

    function _addParams(uint256 a0, uint256 a1, bytes memory route, int24 lo, int24 hi)
        internal
        view
        returns (ISwapAndAdd.AddParams memory)
    {
        return ISwapAndAdd.AddParams({
            poolKey: key,
            tickLower: lo,
            tickUpper: hi,
            amount0In: a0,
            amount1In: a1,
            route: route,
            minLiquidity: 0,
            recipient: address(this),
            hookData: "",
            deadline: block.timestamp + 1
        });
    }

    // ─────────────────────────── empty-route (same-pool) against the real pool ───────────────────────────

    function test_fork_add_usdcBudget_emptyRoute() public {
        (int24 lo, int24 hi) = _ticks();
        _fundUsdc(50_000e6);

        (uint256 tokenId, uint128 liq, uint256 a0, uint256 a1) = zap.add(_addParams(0, 10_000e6, "", lo, hi));

        assertEq(IERC721(POSM).ownerOf(tokenId), address(this), "user owns NFT");
        assertGt(liq, 0, "liquidity minted");
        assertGt(a0, 0, "ETH deployed");
        assertGt(a1, 0, "USDC deployed");
        assertEq(address(zap).balance, 0, "zap eth == 0");
        assertEq(IERC20(USDC).balanceOf(address(zap)), 0, "zap usdc == 0");
    }

    function test_fork_add_ethBudget_emptyRoute() public {
        (int24 lo, int24 hi) = _ticks();
        vm.deal(address(this), 100 ether);

        (uint256 tokenId, uint128 liq, uint256 a0, uint256 a1) = zap.add{value: 5 ether}(_addParams(5 ether, 0, "", lo, hi));

        assertEq(IERC721(POSM).ownerOf(tokenId), address(this), "user owns NFT");
        assertGt(liq, 0, "liquidity minted");
        assertGt(a0, 0, "ETH deployed");
        assertGt(a1, 0, "USDC deployed");
        assertEq(address(zap).balance, 0, "zap eth == 0");
        assertEq(IERC20(USDC).balanceOf(address(zap)), 0, "zap usdc == 0");
    }

    // ─────────────────────────── real-UR route within the zap's unlock ───────────────────────────

    function test_fork_add_usdcBudget_viaURRoute() public {
        (int24 lo, int24 hi) = _ticks();
        _fundUsdc(50_000e6);

        // bulk: sell 4_000 USDC -> ETH on the SAME real pool via the real UR (within the zap's unlock);
        // the same-pool reconcile + trim finish the position.
        bytes memory route = _v4SwapRoute(key, false, 4_000e6, key.currency1, key.currency0);

        (uint256 tokenId, uint128 liq,,) = zap.add(_addParams(0, 10_000e6, route, lo, hi));

        assertEq(IERC721(POSM).ownerOf(tokenId), address(this), "user owns NFT");
        assertGt(liq, 0, "liquidity minted");
        assertEq(address(zap).balance, 0, "zap eth == 0");
        assertEq(IERC20(USDC).balanceOf(address(zap)), 0, "zap usdc == 0");
    }

    /// @notice Route-first against the REAL UR: with a well-sized route (route does the bulk), almost the entire
    ///         budget is deployed — the recipient gets back only tiny dust (route-first sizes from real holdings,
    ///         so it does not return the route's execution slice the way a size-then-swap design would).
    function test_fork_add_usdcBudget_viaURRoute_lowDust() public {
        (int24 lo, int24 hi) = _ticks();
        _fundUsdc(50_000e6);

        uint256 usdcBefore = IERC20(USDC).balanceOf(address(this));
        uint256 ethBefore = address(this).balance;

        // route ~half the budget (the bulk) USDC -> ETH on the real pool; reconcile + trim finish it.
        bytes memory route = _v4SwapRoute(key, false, 5_000e6, key.currency1, key.currency0);
        (uint256 tokenId, uint128 liq,,) = zap.add(_addParams(0, 10_000e6, route, lo, hi));

        uint256 usdcReturned = IERC20(USDC).balanceOf(address(this)) + 10_000e6 - usdcBefore; // budget pulled was 10_000
        assertEq(IERC721(POSM).ownerOf(tokenId), address(this), "user owns NFT");
        assertGt(liq, 0, "liquidity minted");
        // route-first deploys nearly all of it: returned USDC is a small fraction of the 10_000 budget.
        assertLt(usdcReturned, 200e6, "returned USDC < 2% of budget");
        // the swapped-into token (ETH) is not returned to the user beyond dust.
        assertApproxEqAbs(address(this).balance, ethBefore, 1e12, "no meaningful ETH dust to user");
        assertEq(address(zap).balance, 0, "zap eth == 0");
        assertEq(IERC20(USDC).balanceOf(address(zap)), 0, "zap usdc == 0");
    }

    function _rebalanceParams(uint256 tokenId, uint256 redeployBps, int24 lo, int24 hi)
        internal
        view
        returns (ISwapAndAdd.RebalanceParams memory)
    {
        return ISwapAndAdd.RebalanceParams({
            tokenId: tokenId,
            redeployBps: redeployBps,
            newTickLower: lo,
            newTickUpper: hi,
            route: "",
            minLiquidity: 0,
            recipient: address(this),
            hookData: "",
            deadline: block.timestamp + 1
        });
    }

    // ─────────────────────────── rebalance on the real pool ───────────────────────────

    function test_fork_rebalance_full() public {
        (int24 lo, int24 hi) = _ticks();
        _fundUsdc(50_000e6);
        (uint256 tokenId,,,) = zap.add(_addParams(0, 10_000e6, "", lo, hi));
        IERC721(POSM).setApprovalForAll(address(zap), true);

        int24 ts = key.tickSpacing;
        (uint256 newTokenId, uint128 newLiq,,) =
            zap.rebalance(_rebalanceParams(tokenId, 10_000, lo - 10 * ts, hi + 10 * ts));

        assertEq(IERC721(POSM).ownerOf(newTokenId), address(this), "user owns new NFT");
        assertGt(newLiq, 0, "new liquidity minted");
        assertEq(posm.getPositionLiquidity(tokenId), 0, "old position fully burned");
        assertEq(address(zap).balance, 0, "zap eth == 0");
        assertEq(IERC20(USDC).balanceOf(address(zap)), 0, "zap usdc == 0");
    }

    // Option-a partial redeploy on the real pool: the old position is burned IN FULL, half is redeployed, and
    // the other half is returned to the recipient's wallet (in both ETH and USDC).
    function test_fork_rebalance_partialRedeploy() public {
        (int24 lo, int24 hi) = _ticks();
        _fundUsdc(50_000e6);
        (uint256 tokenId,,,) = zap.add(_addParams(0, 10_000e6, "", lo, hi));
        IERC721(POSM).setApprovalForAll(address(zap), true);
        int24 ts = key.tickSpacing;

        uint256 usdcBefore = IERC20(USDC).balanceOf(address(this));
        uint256 ethBefore = address(this).balance;
        (uint256 newTokenId, uint128 newLiq,,) =
            zap.rebalance(_rebalanceParams(tokenId, 5_000, lo - 10 * ts, hi + 10 * ts));

        assertEq(IERC721(POSM).ownerOf(newTokenId), address(this), "user owns new NFT");
        assertGt(newLiq, 0, "new liquidity minted");
        assertEq(posm.getPositionLiquidity(tokenId), 0, "old position fully burned");
        // the un-redeployed half is returned to the recipient in BOTH tokens.
        assertGt(IERC20(USDC).balanceOf(address(this)), usdcBefore, "usdc returned to recipient");
        assertGt(address(this).balance, ethBefore, "eth returned to recipient");
        assertEq(address(zap).balance, 0, "zap eth == 0");
        assertEq(IERC20(USDC).balanceOf(address(zap)), 0, "zap usdc == 0");
    }

    // Repro: full rebalance into the SAME range as the old position (the UI's default).
    function test_fork_rebalance_sameRange_full() public {
        (int24 lo, int24 hi) = _ticks();
        _fundUsdc(50_000e6);
        (uint256 tokenId,,,) = zap.add(_addParams(0, 10_000e6, "", lo, hi));
        IERC721(POSM).setApprovalForAll(address(zap), true);

        zap.rebalance(_rebalanceParams(tokenId, 10_000, lo, hi)); // new range == old range
    }

    // Faithful repro of the in-browser flow: 0.5 ETH add, then same-range full rebalance.
    function test_fork_rebalance_sameRange_full_halfEth() public {
        (int24 lo, int24 hi) = _ticks();
        vm.deal(address(this), 100 ether);
        (uint256 tokenId,,,) = zap.add{value: 0.5 ether}(_addParams(0.5 ether, 0, "", lo, hi));
        IERC721(POSM).setApprovalForAll(address(zap), true);
        zap.rebalance(_rebalanceParams(tokenId, 10_000, lo, hi));
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

    receive() external payable {}
}
