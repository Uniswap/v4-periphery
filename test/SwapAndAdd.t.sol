// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {Pool} from "@uniswap/v4-core/src/libraries/Pool.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {FixedPoint96} from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {IERC721} from "forge-std/interfaces/IERC721.sol";

import {PosmTestSetup} from "./shared/PosmTestSetup.sol";
import {LiquidityAmounts} from "../src/libraries/LiquidityAmounts.sol";
import {PositionConfig} from "./shared/PositionConfig.sol";
import {MockSwapRoute} from "./mocks/MockSwapRoute.sol";
import {MockERC20ApproveNoReturn} from "./mocks/MockERC20ApproveNoReturn.sol";
import {MockERC20Permit2Native} from "./mocks/MockERC20Permit2Native.sol";
import {MockERC20ApproveRace} from "./mocks/MockERC20ApproveRace.sol";
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
        // Deploy SwapAndAdd from its precompiled (via_ir=true/500) artifact rather than `new SwapAndAdd(...)`,
        // so its source is never pulled into this via_ir=false test unit — mirrors how PosmTestSetup deploys
        // PositionManager via vm.getCode. This lets SwapAndAdd be pinned to the posm profile for production
        // (fits the 24576 size limit) without a settings conflict against the test build.
        zap = ISwapAndAdd(
            deployCode("SwapAndAdd.sol:SwapAndAdd", abi.encode(manager, permit2, lpm, IUniversalRouter(address(route))))
        );
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

    function _addParams(uint256 amount0In, uint256 amount1In) internal view returns (ISwapAndAdd.AddParams memory) {
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

    // ─────────────────────────── increase (top up an existing position) ───────────────────────────

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
            minLiquidityAdded: 0,
            recipient: address(this),
            hookData: "",
            deadline: block.timestamp + 1
        });
    }

    /// @dev Increase tops up the SAME tokenId in place: liquidity grows, no new NFT, owner unchanged.
    ///      POSM gates INCREASE_LIQUIDITY on the locker (zap) being approved, so the owner approves it first.
    function test_increase_growsSamePosition() public {
        (uint256 tokenId, uint128 liq0,,) = zap.add(_addParams(0, 10e18));
        IERC721(address(lpm)).setApprovalForAll(address(zap), true);
        uint256 nextBefore = lpm.nextTokenId();

        (uint128 added, uint256 a0, uint256 a1) = zap.increase(_increaseParams(tokenId, 0, 10e18));

        assertGt(added, 0, "liquidity added");
        assertGt(a0 + a1, 0, "amounts deployed");
        assertEq(lpm.getPositionLiquidity(tokenId), liq0 + added, "same position grew by exactly added");
        assertEq(lpm.nextTokenId(), nextBefore, "no new NFT minted");
        assertEq(IERC721(address(lpm)).ownerOf(tokenId), address(this), "owner unchanged");
        assertEq(currency0.balanceOf(address(zap)), 0, "zap token0 == 0");
        assertEq(currency1.balanceOf(address(zap)), 0, "zap token1 == 0");
    }

    function test_increase_singleToken0() public {
        (uint256 tokenId, uint128 liq0,,) = zap.add(_addParams(0, 10e18));
        IERC721(address(lpm)).setApprovalForAll(address(zap), true);
        (uint128 added,,) = zap.increase(_increaseParams(tokenId, 10e18, 0));
        assertGt(added, 0, "liquidity added");
        assertEq(lpm.getPositionLiquidity(tokenId), liq0 + added, "grew by added");
        assertEq(currency0.balanceOf(address(zap)), 0, "zap token0 == 0");
        assertEq(currency1.balanceOf(address(zap)), 0, "zap token1 == 0");
    }

    function test_increase_mixedRatio() public {
        (uint256 tokenId, uint128 liq0,,) = zap.add(_addParams(3e18, 10e18));
        IERC721(address(lpm)).setApprovalForAll(address(zap), true);
        (uint128 added,,) = zap.increase(_increaseParams(tokenId, 2e18, 10e18));
        assertGt(added, 0, "liquidity added");
        assertEq(lpm.getPositionLiquidity(tokenId), liq0 + added, "grew by added");
        assertEq(currency0.balanceOf(address(zap)), 0, "zap token0 == 0");
        assertEq(currency1.balanceOf(address(zap)), 0, "zap token1 == 0");
    }

    function test_increase_native() public {
        ISwapAndAdd.AddParams memory ap = _addParams(1e17, 0);
        ap.poolKey = nativeKey;
        (uint256 tokenId, uint128 liq0,,) = zap.add{value: 1e17}(ap);
        IERC721(address(lpm)).setApprovalForAll(address(zap), true);
        uint256 nextBefore = lpm.nextTokenId();

        (uint128 added,,) = zap.increase{value: 1e17}(_increaseParams(tokenId, 1e17, 0));

        assertGt(added, 0, "liquidity added");
        assertEq(lpm.getPositionLiquidity(tokenId), liq0 + added, "native position grew by added");
        assertEq(lpm.nextTokenId(), nextBefore, "no new NFT minted");
        assertEq(address(zap).balance, 0, "zap eth == 0");
    }

    function test_increase_revertsOnMinLiquidity() public {
        (uint256 tokenId,,,) = zap.add(_addParams(0, 10e18));
        IERC721(address(lpm)).setApprovalForAll(address(zap), true);
        ISwapAndAdd.IncreaseParams memory p = _increaseParams(tokenId, 0, 10e18);
        p.minLiquidityAdded = type(uint128).max; // impossible floor on the liquidity added
        vm.expectRevert(); // InsufficientLiquidity
        zap.increase(p);
    }

    function test_increase_revertsAfterDeadline() public {
        (uint256 tokenId,,,) = zap.add(_addParams(0, 10e18));
        ISwapAndAdd.IncreaseParams memory p = _increaseParams(tokenId, 0, 10e18);
        p.deadline = block.timestamp - 1;
        vm.expectRevert(abi.encodeWithSelector(ISwapAndAdd.DeadlinePassed.selector, p.deadline));
        zap.increase(p);
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

    function _rebalanceParams(uint256 tokenId, int128 additionalA, int128 additionalB)
        internal
        view
        returns (ISwapAndAdd.RebalanceParams memory)
    {
        return ISwapAndAdd.RebalanceParams({
            tokenId: tokenId,
            additionalA: additionalA,
            additionalB: additionalB,
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

        // (0, 0) deltas -> full move: burn the whole position, redeploy everything, add/return nothing.
        (uint256 newTokenId, uint128 newLiq,,) = zap.rebalance(_rebalanceParams(tokenId, 0, 0));

        assertEq(IERC721(address(lpm)).ownerOf(newTokenId), address(this), "user owns new NFT");
        assertGt(newLiq, 0, "new liquidity minted");
        assertEq(lpm.getPositionLiquidity(tokenId), 0, "old position fully burned");
        assertEq(currency0.balanceOf(address(zap)), 0, "zap token0 == 0");
        assertEq(currency1.balanceOf(address(zap)), 0, "zap token1 == 0");
    }

    /// @dev Negative delta (cash-out): the old position is burned IN FULL, a chosen amount of token1 is returned
    ///      to the recipient's wallet, and only the remainder is redeployed -> less liquidity than a full move.
    function test_rebalance_negativeDelta_cashOut() public {
        IERC721(address(lpm)).setApprovalForAll(address(zap), true);
        (uint256 idFull,,,) = zap.add(_addParams(0, 10e18));
        (uint256 idCash,,,) = zap.add(_addParams(0, 10e18));

        (, uint128 liqFull,,) = zap.rebalance(_rebalanceParams(idFull, 0, 0));

        int128 ret1 = 1e18; // return 1 token1 to the wallet
        uint256 c1Before = currency1.balanceOf(address(this));
        (, uint128 liqCash,,) = zap.rebalance(_rebalanceParams(idCash, 0, -ret1));
        uint256 refund1 = currency1.balanceOf(address(this)) - c1Before;

        assertEq(lpm.getPositionLiquidity(idFull), 0, "full burned");
        assertEq(lpm.getPositionLiquidity(idCash), 0, "cash-out burned");
        assertLt(liqCash, liqFull, "cashing out token1 deploys less than a full redeploy");
        assertGe(refund1, uint256(uint128(ret1)), "recipient received at least the cashed-out token1");
        assertEq(currency0.balanceOf(address(zap)), 0, "zap token0 == 0");
        assertEq(currency1.balanceOf(address(zap)), 0, "zap token1 == 0");
    }

    /// @dev Positive delta (rebalance + add): pull MORE token1 from the wallet on top of the withdrawn holdings,
    ///      so the new position is LARGER than a plain full redeploy of the same burned position.
    function test_rebalance_positiveDelta_addsMore() public {
        IERC721(address(lpm)).setApprovalForAll(address(zap), true);
        (uint256 idFull,,,) = zap.add(_addParams(0, 10e18));
        (uint256 idAdd,,,) = zap.add(_addParams(0, 10e18));

        (, uint128 liqFull,,) = zap.rebalance(_rebalanceParams(idFull, 0, 0));
        (, uint128 liqAdd,,) = zap.rebalance(_rebalanceParams(idAdd, 0, 5e18)); // add 5 more token1 from the wallet

        assertGt(liqAdd, liqFull, "adding token1 deploys MORE than a full redeploy");
        assertEq(lpm.getPositionLiquidity(idAdd), 0, "old burned");
        assertEq(currency0.balanceOf(address(zap)), 0, "zap token0 == 0");
        assertEq(currency1.balanceOf(address(zap)), 0, "zap token1 == 0");
    }

    /// @dev Mixed signs in one tx: pull more token0 from the wallet while returning some token1 to it.
    function test_rebalance_mixedSigns() public {
        IERC721(address(lpm)).setApprovalForAll(address(zap), true);
        (uint256 tokenId,,,) = zap.add(_addParams(3e18, 10e18)); // two-sided position

        uint256 c1Before = currency1.balanceOf(address(this));
        (uint256 newId, uint128 newLiq,,) = zap.rebalance(_rebalanceParams(tokenId, 2e18, -1e18)); // +token0, -token1
        uint256 refund1 = currency1.balanceOf(address(this)) - c1Before;

        assertEq(IERC721(address(lpm)).ownerOf(newId), address(this), "user owns new NFT");
        assertGt(newLiq, 0, "new liquidity minted");
        assertEq(lpm.getPositionLiquidity(tokenId), 0, "old burned");
        assertGe(refund1, 1e18, "recipient received the returned token1");
        assertEq(currency0.balanceOf(address(zap)), 0, "zap token0 == 0");
        assertEq(currency1.balanceOf(address(zap)), 0, "zap token1 == 0");
    }

    function test_rebalance_revertsOnOverWithdrawal() public {
        (uint256 tokenId,,,) = zap.add(_addParams(0, 10e18));
        IERC721(address(lpm)).setApprovalForAll(address(zap), true);
        // try to return far more token1 than the burned position holds -> clamp revert.
        vm.expectPartialRevert(ISwapAndAdd.ReturnExceedsWithdrawn.selector);
        zap.rebalance(_rebalanceParams(tokenId, 0, -100e18));
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

    /// @dev Regression: a range entirely BELOW spot needs zero token0, so on a native pool the mint must
    ///      forward zero value — an unheld extra wei (the former rounding buffer) reverted OutOfFunds here.
    function test_add_native_belowRange_singleToken1() public {
        ISwapAndAdd.AddParams memory p = _addParams(0, 5e18);
        p.poolKey = nativeKey;
        p.tickLower = -1200;
        p.tickUpper = -660;

        (uint256 tokenId, uint128 liq,,) = zap.add(p);

        assertEq(IERC721(address(lpm)).ownerOf(tokenId), address(this), "user owns NFT");
        assertGt(liq, 0, "liquidity minted");
        assertEq(address(zap).balance, 0, "zap eth == 0");
        assertEq(currency1.balanceOf(address(zap)), 0, "zap token1 == 0");
    }

    /// @dev Regression: Slot0's protocolFee packs TWO directional 12-bit fees; treating the packed value as
    ///      plain pips made `PIPS_DENOMINATOR - feePips` underflow for any nonzero one-for-zero component,
    ///      bricking every reconcile-needing operation on the pool. Sizing must use the direction's swap fee.
    function test_add_directionalProtocolFeeSet() public {
        vm.prank(feeController);
        manager.setProtocolFee(key, uint24((250 << 12) | 250)); // 0.025% both directions, packed

        (uint256 tokenId, uint128 liq,,) = zap.add(_addParams(10e18, 0));
        assertEq(IERC721(address(lpm)).ownerOf(tokenId), address(this), "user owns NFT");
        assertGt(liq, 0, "liquidity minted with directional protocol fee");

        // and the other surplus direction (token1 surplus -> one-for-zero reconcile)
        (, uint128 liq1,,) = zap.add(_addParams(0, 10e18));
        assertGt(liq1, 0, "liquidity minted, token1-surplus direction");
    }

    function test_rebalance_revertsIfNotAuthorized() public {
        (uint256 tokenId,,,) = zap.add(_addParams(0, 10e18));
        // do NOT approve the zap; call from a stranger
        vm.prank(address(0xBEEF));
        vm.expectRevert();
        zap.rebalance(_rebalanceParams(tokenId, 0, 0));
    }

    /// @dev SECURITY: an approved operator may rebalance the owner's position but must NOT be able to redirect its
    ///      value to itself. Even when the operator sets `recipient = self`, the new NFT and any cash-out are forced
    ///      to the position owner — so a standing NFT approval can never be used to steal the position.
    function test_rebalance_operatorCannotRedirectToSelf() public {
        address operator = address(0xBEEF);
        (uint256 tokenId,,,) = zap.add(_addParams(0, 10e18));
        IERC721(address(lpm)).setApprovalForAll(address(zap), true); // zap may burn/redeploy
        IERC721(address(lpm)).setApprovalForAll(operator, true); // owner trusts operator to MANAGE the position

        ISwapAndAdd.RebalanceParams memory p = _rebalanceParams(tokenId, 0, -1e18); // cash out 1 token1
        p.recipient = operator; // operator tries to send the output to itself

        uint256 opC1Before = currency1.balanceOf(operator);
        uint256 ownerC1Before = currency1.balanceOf(address(this));
        vm.prank(operator);
        (uint256 newTokenId,,,) = zap.rebalance(p);

        assertEq(IERC721(address(lpm)).ownerOf(newTokenId), address(this), "new NFT forced to owner, not operator");
        assertEq(currency1.balanceOf(operator), opC1Before, "operator received NO cash-out");
        assertGe(currency1.balanceOf(address(this)) - ownerC1Before, 1e18, "owner received the cash-out");
    }

    /// @dev Counterpart to the guard test: the owner themselves CAN still direct the output to any address.
    function test_rebalance_ownerMayChooseRecipient() public {
        address dest = address(0xCAFE);
        (uint256 tokenId,,,) = zap.add(_addParams(0, 10e18));
        IERC721(address(lpm)).setApprovalForAll(address(zap), true);

        ISwapAndAdd.RebalanceParams memory p = _rebalanceParams(tokenId, 0, 0);
        p.recipient = dest;
        (uint256 newTokenId,,,) = zap.rebalance(p); // owner is msg.sender

        assertEq(IERC721(address(lpm)).ownerOf(newTokenId), dest, "owner may send the new NFT to a chosen recipient");
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
        ISwapAndAdd.RebalanceParams memory p = _rebalanceParams(tokenId, 0, 0);
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

    // ─────────────────────────── native-ETH rebalance (signed deltas) ───────────────────────────

    function _nativeAdd(uint256 nativeIn) internal returns (uint256 tokenId) {
        ISwapAndAdd.AddParams memory p = _addParams(nativeIn, 0);
        p.poolKey = nativeKey;
        (tokenId,,,) = zap.add{value: nativeIn}(p);
    }

    /// @dev Native positive delta: add more native ETH (via msg.value) during a rebalance of a native position;
    ///      the new position is larger than a plain full redeploy of the same burned holdings.
    function test_rebalance_native_positiveDelta_addsMore() public {
        uint256 tokenId = _nativeAdd(5e17); // 0.5 ETH position
        IERC721(address(lpm)).setApprovalForAll(address(zap), true);

        uint256 snap = vm.snapshotState();
        (, uint128 liqBase,,) = zap.rebalance(_rebalanceParams(tokenId, 0, 0));
        vm.revertToState(snap);

        int128 addNative = 1e17; // add 0.1 ETH more from the wallet
        (, uint128 liqMore,,) =
            zap.rebalance{value: uint256(uint128(addNative))}(_rebalanceParams(tokenId, addNative, 0));

        assertGt(liqMore, liqBase, "adding native ETH deploys more than a full redeploy");
        assertEq(address(zap).balance, 0, "zap eth == 0");
        assertEq(currency1.balanceOf(address(zap)), 0, "zap token1 == 0");
    }

    function test_rebalance_native_revertsOnWrongEthValue() public {
        uint256 tokenId = _nativeAdd(5e17);
        IERC721(address(lpm)).setApprovalForAll(address(zap), true);
        // msg.value must equal the positive native delta; send one wei short -> revert.
        vm.expectRevert(ISwapAndAdd.InvalidEthValue.selector);
        zap.rebalance{value: 1e17 - 1}(_rebalanceParams(tokenId, 1e17, 0));
    }

    // ─────────────────────────── compound (reinvest fees) ───────────────────────────

    function _compoundParams(uint256 tokenId, uint256 minLiquidityAdded)
        internal
        view
        returns (ISwapAndAdd.CompoundParams memory)
    {
        return ISwapAndAdd.CompoundParams({
            tokenId: tokenId,
            route: "",
            minLiquidityAdded: minLiquidityAdded,
            recipient: address(this),
            hookData: "",
            deadline: block.timestamp + 1
        });
    }

    /// @dev Accrue fees to in-range liquidity via balanced round-trip swaps (price returns near 1:1, both sides
    ///      collect fees).
    function _generateFees() internal {
        for (uint256 i = 0; i < 5; i++) {
            swap(key, true, -50e18, "");
            swap(key, false, -50e18, "");
        }
    }

    function test_compound_reinvestsFees() public {
        (uint256 tokenId, uint128 liq0,,) = zap.add(_addParams(0, 10e18));
        IERC721(address(lpm)).setApprovalForAll(address(zap), true);
        _generateFees();

        uint256 c0Before = currency0.balanceOf(address(this));
        uint256 c1Before = currency1.balanceOf(address(this));

        (uint128 added, uint256 a0, uint256 a1) = zap.compound(_compoundParams(tokenId, 0));

        assertGt(added, 0, "fees reinvested as liquidity");
        assertGt(a0 + a1, 0, "amounts reinvested");
        assertEq(IERC721(address(lpm)).ownerOf(tokenId), address(this), "NFT still owned by user");
        assertEq(lpm.getPositionLiquidity(tokenId), liq0 + added, "position grew by exactly the added liquidity");
        // the fees were reinvested, not paid out: anything that reached the wallet is only swept dust, far less
        // than what was compounded into the position.
        assertLt(currency0.balanceOf(address(this)) - c0Before, a0 + 1, "token0 fees compounded, not paid out");
        assertLt(currency1.balanceOf(address(this)) - c1Before, a1 + 1, "token1 fees compounded, not paid out");
        assertEq(currency0.balanceOf(address(zap)), 0, "zap token0 == 0");
        assertEq(currency1.balanceOf(address(zap)), 0, "zap token1 == 0");
    }

    function test_compound_revertsOnMinLiquidity() public {
        (uint256 tokenId,,,) = zap.add(_addParams(0, 10e18));
        IERC721(address(lpm)).setApprovalForAll(address(zap), true);
        _generateFees();
        vm.expectRevert(); // impossible floor on the added liquidity
        zap.compound(_compoundParams(tokenId, type(uint128).max));
    }

    function test_compound_revertsIfNotAuthorized() public {
        (uint256 tokenId,,,) = zap.add(_addParams(0, 10e18));
        _generateFees();
        vm.prank(address(0xBEEF)); // stranger, zap not approved
        vm.expectRevert();
        zap.compound(_compoundParams(tokenId, 0));
    }

    /// @dev A position with no accrued fees can't compound. Mint directly (no swap) so it genuinely has zero fees.
    function test_compound_revertsWhenNoFees() public {
        uint256 tokenId = lpm.nextTokenId();
        PositionConfig memory cfg = PositionConfig({poolKey: key, tickLower: TICK_LOWER, tickUpper: TICK_UPPER});
        mint(cfg, 1e18, address(this), "");
        IERC721(address(lpm)).setApprovalForAll(address(zap), true);
        vm.expectRevert(ISwapAndAdd.NoFeesToCompound.selector);
        zap.compound(_compoundParams(tokenId, 0));
    }

    /// @dev SECURITY: an approved operator may compound the owner's fees, but the NFT never moves and any swept
    ///      dust is forced to the owner — the operator cannot skim even rounding dust by setting recipient = self.
    function test_compound_operatorCannotRedirectDust() public {
        address operator = address(0xBEEF);
        (uint256 tokenId,,,) = zap.add(_addParams(0, 10e18));
        IERC721(address(lpm)).setApprovalForAll(address(zap), true);
        IERC721(address(lpm)).setApprovalForAll(operator, true);
        _generateFees();

        ISwapAndAdd.CompoundParams memory p = _compoundParams(tokenId, 0);
        p.recipient = operator; // operator tries to grab any dust

        uint256 opC0Before = currency0.balanceOf(operator);
        uint256 opC1Before = currency1.balanceOf(operator);
        vm.prank(operator);
        zap.compound(p);

        assertEq(IERC721(address(lpm)).ownerOf(tokenId), address(this), "NFT stays with owner");
        assertEq(currency0.balanceOf(operator), opC0Before, "operator got no token0 dust");
        assertEq(currency1.balanceOf(operator), opC1Before, "operator got no token1 dust");
    }

    /// @dev Compound may route the collected fees like every other op; the reconcile absorbs whatever the
    ///      route leaves. The route input is sized from a dry-run — the onchain stand-in for an integrator
    ///      quoting the position's unclaimed fees offchain.
    function test_compound_withRoute() public {
        (uint256 tokenId, uint128 liq0,,) = zap.add(_addParams(0, 10e18));
        IERC721(address(lpm)).setApprovalForAll(address(zap), true);
        _generateFees();

        uint256 snap = vm.snapshotState();
        (,, uint256 a1Base) = zap.compound(_compoundParams(tokenId, 0));
        vm.revertToState(snap);

        _configRoute(10100, a1Base / 2); // convert half the token1 fees at mid+1%
        ISwapAndAdd.CompoundParams memory p = _compoundParams(tokenId, 0);
        p.route = ROUTE_PAYLOAD;

        uint256 routeC1Before = currency1.balanceOf(address(route));
        (uint128 added,,) = zap.compound(p);

        assertGt(added, 0, "fees compounded");
        assertEq(lpm.getPositionLiquidity(tokenId), liq0 + added, "same position grew by exactly added");
        assertEq(currency1.balanceOf(address(route)) - routeC1Before, a1Base / 2, "route consumed its declared input");
        assertEq(currency0.balanceOf(address(zap)), 0, "zap token0 == 0");
        assertEq(currency1.balanceOf(address(zap)), 0, "zap token1 == 0");
    }

    // ─────────────────────────── sizing / reconcile extremes ───────────────────────────

    /// @dev ERC-20 counterpart of the native below-range case: the position needs zero token0, the whole
    ///      budget-side reconcile happens on token1 alone.
    function test_add_belowRange_singleToken1() public {
        ISwapAndAdd.AddParams memory p = _addParams(0, 5e18);
        p.tickLower = -1200;
        p.tickUpper = -660;
        (uint256 tokenId, uint128 liq,,) = zap.add(p);
        assertEq(IERC721(address(lpm)).ownerOf(tokenId), address(this), "user owns NFT");
        assertGt(liq, 0, "liquidity minted");
        assertEq(currency0.balanceOf(address(zap)), 0, "zap token0 == 0");
        assertEq(currency1.balanceOf(address(zap)), 0, "zap token1 == 0");
    }

    /// @dev Range entirely BELOW spot funded with token0 only: the position is 100% token1, so the ENTIRE
    ///      deficit is flash-taken and the reconcile sell starts from a price above the range — the trim's
    ///      min(price, sqrtUpper) clamp is what sizes the decrease correctly there.
    function test_add_belowRange_singleToken0() public {
        ISwapAndAdd.AddParams memory p = _addParams(-1200, -660, 10e18, 0);
        (uint256 tokenId, uint128 liq,,) = zap.add(p);
        assertEq(IERC721(address(lpm)).ownerOf(tokenId), address(this), "user owns NFT");
        assertGt(liq, 0, "liquidity minted");
        assertEq(currency0.balanceOf(address(zap)), 0, "zap token0 == 0");
        assertEq(currency1.balanceOf(address(zap)), 0, "zap token1 == 0");
    }

    /// @dev Narrow range with a one-sided budget larger than the pool's external depth: the reconcile sell
    ///      pushes the price BELOW the just-minted range, yet the operation still lands (the surplus input is
    ///      valued at the pre-swap price, so it exhausts at/before the boundary and the trim can always free
    ///      the deficit side from the just-added liquidity).
    function test_add_narrowRange_hugeSingleSided() public {
        (uint256 tokenId, uint128 liq,,) = zap.add(_addParams(-60, 60, 1_500e18, 0));
        assertEq(IERC721(address(lpm)).ownerOf(tokenId), address(this), "user owns NFT");
        assertGt(liq, 0, "liquidity minted");
        assertEq(currency0.balanceOf(address(zap)), 0, "zap token0 == 0");
        assertEq(currency1.balanceOf(address(zap)), 0, "zap token1 == 0");
    }

    /// @dev Thin pool (1e15 external liquidity vs a 500e18 one-sided budget), narrow range: the reconcile must
    ///      traverse far more depth than exists outside the just-minted position and still settle cleanly.
    function test_add_thinPool_hugeSingleSided() public {
        PoolKey memory thin = _thinPool();
        ISwapAndAdd.AddParams memory p = _addParams(-60, 60, 500e18, 0);
        p.poolKey = thin;
        (, uint128 liq,,) = zap.add(p);
        assertGt(liq, 0, "liquidity minted on thin pool");
        assertEq(currency0.balanceOf(address(zap)), 0, "zap token0 == 0");
        assertEq(currency1.balanceOf(address(zap)), 0, "zap token1 == 0");
    }

    /// @dev Thin pool with spot exactly AT the range's upper boundary (position = 100% token1) and a token0-only
    ///      budget: the whole budget is surplus and the whole position is flash-taken deficit — the knife-edge
    ///      where the reconcile sell must fund the entire mint.
    function test_add_thinPool_priceAtUpperEdge_token0Only() public {
        PoolKey memory thin = _thinPool();
        ISwapAndAdd.AddParams memory p = _addParams(-600, 0, 200e18, 0); // tickUpper == current tick
        p.poolKey = thin;
        (, uint128 liq,,) = zap.add(p);
        assertGt(liq, 0, "liquidity minted at upper edge");
        assertEq(currency0.balanceOf(address(zap)), 0, "zap token0 == 0");
        assertEq(currency1.balanceOf(address(zap)), 0, "zap token1 == 0");
    }

    /// @dev Any two-sided budget must land: hunts the both-sides-short knife-edge where round-up makes BOTH
    ///      optimistic amounts exceed the budget by a wei (both sides flash-taken), and every in-between ratio.
    function testFuzz_add_twoSided(uint256 a0, uint256 a1) public {
        a0 = bound(a0, 1e6, 500e18);
        a1 = bound(a1, 1e6, 500e18);
        (uint256 tokenId, uint128 liq,,) = zap.add(_addParams(a0, a1));
        assertEq(IERC721(address(lpm)).ownerOf(tokenId), address(this), "user owns NFT");
        assertGt(liq, 0, "liquidity minted");
        assertEq(currency0.balanceOf(address(zap)), 0, "zap token0 == 0");
        assertEq(currency1.balanceOf(address(zap)), 0, "zap token1 == 0");
    }

    function _addParams(int24 tickLower, int24 tickUpper, uint256 amount0In, uint256 amount1In)
        internal
        view
        returns (ISwapAndAdd.AddParams memory p)
    {
        p = _addParams(amount0In, amount1In);
        p.tickLower = tickLower;
        p.tickUpper = tickUpper;
    }

    /// @dev Spin up a native-ETH/token pool with depth for the weird-token `_ensureApproved` regressions.
    function _initWeirdTokenPool(address token) internal returns (PoolKey memory k) {
        (k,) = initPoolAndAddLiquidityETH(
            CurrencyLibrary.ADDRESS_ZERO, Currency.wrap(token), IHooks(address(0)), 3000, SQRT_PRICE_1_1, 1 ether
        );
        modifyLiquidityRouter.modifyLiquidity{value: 50 ether}(
            k,
            ModifyLiquidityParams({tickLower: -600, tickUpper: 600, liquidityDelta: int256(uint256(200e18)), salt: 0}),
            ""
        );
    }

    /// @dev Regression: `_ensureApproved` must tolerate tokens whose approve returns nothing (USDT-style) —
    ///      a plain IERC20(returns bool) approve reverts on decode and would brick every pool of that token.
    function test_add_approveNoReturnToken() public {
        MockERC20ApproveNoReturn usdt = new MockERC20ApproveNoReturn();
        usdt.mint(address(this), 1_000e18);
        usdt.approve(address(permit2), type(uint256).max);
        permit2.approve(address(usdt), address(zap), type(uint160).max, type(uint48).max);
        usdt.approve(address(modifyLiquidityRouter), type(uint256).max);
        PoolKey memory k = _initWeirdTokenPool(address(usdt));

        ISwapAndAdd.AddParams memory p = _addParams(0, 5e18);
        p.poolKey = k;
        (uint256 tokenId, uint128 liq,,) = zap.add(p);

        assertEq(IERC721(address(lpm)).ownerOf(tokenId), address(this), "user owns NFT");
        assertGt(liq, 0, "liquidity minted on approve-no-return token pool");
        assertEq(address(zap).balance, 0, "zap eth == 0");
        assertEq(usdt.balanceOf(address(zap)), 0, "zap token == 0");
    }

    /// @dev Regression: a Permit2-native token hardcodes an infinite Permit2 allowance (and reverts approve()
    ///      toward it). `_ensureApproved` must not read that allowance as proof of its own wiring — the
    ///      Permit2-internal grants to POSM/UR wouldn't exist — and must skip the redundant ERC20 approve,
    ///      which here would revert and brick every pool of that token.
    function test_add_permit2NativeToken() public {
        MockERC20Permit2Native token = new MockERC20Permit2Native(address(permit2));
        token.mint(address(this), 1_000e18);
        // no token.approve(permit2) — hardcoded; the user only grants the Permit2 allowance to the zap
        permit2.approve(address(token), address(zap), type(uint160).max, type(uint48).max);
        token.approve(address(modifyLiquidityRouter), type(uint256).max);
        PoolKey memory k = _initWeirdTokenPool(address(token));

        ISwapAndAdd.AddParams memory p = _addParams(0, 5e18);
        p.poolKey = k;
        (uint256 tokenId, uint128 liq,,) = zap.add(p);

        assertEq(IERC721(address(lpm)).ownerOf(tokenId), address(this), "user owns NFT");
        assertGt(liq, 0, "liquidity minted on permit2-native token pool");
        // the wiring granted the standing Permit2 allowances despite skipping the ERC20 approve
        (uint160 posmAmount,,) = permit2.allowance(address(zap), address(token), address(lpm));
        (uint160 urAmount,,) = permit2.allowance(address(zap), address(token), address(route));
        assertEq(posmAmount, type(uint160).max, "POSM permit2 allowance granted");
        assertEq(urAmount, type(uint160).max, "UR permit2 allowance granted");

        // steady state: the wiring is detected from the Permit2 marker, never re-touching the token's approve
        (, liq,,) = zap.add(p);
        assertGt(liq, 0, "second add on already-wired token");
    }

    /// @dev `_pullBudget` assumes currency1 is never native (native sorts to currency0; PoolManager enforces
    ///      currency0 < currency1, so no pool with currency1 == 0 can ever be initialized). A key smuggling
    ///      native into currency1 must revert: the Permit2 pull for "token" address(0) has no allowance
    ///      (AllowanceExpired) — and even a caller who pre-approves address(0), turning Permit2's pull on the
    ///      codeless address into a silent no-op, dies at the uninitialized pool, unwinding atomically.
    function test_add_revertsOnNativeAsCurrency1() public {
        ISwapAndAdd.AddParams memory p = _addParams(0, 5e18);
        p.poolKey = PoolKey({
            currency0: currency0,
            currency1: CurrencyLibrary.ADDRESS_ZERO,
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });

        vm.expectRevert(abi.encodeWithSelector(IAllowanceTransfer.AllowanceExpired.selector, 0));
        zap.add(p);

        permit2.approve(address(0), address(zap), type(uint160).max, type(uint48).max);
        vm.expectRevert(Pool.PoolNotInitialized.selector);
        zap.add(p);
    }

    /// @dev Regression: `_ensureApproved`'s self-heal — if the ERC20 allowance to Permit2 ever degrades below
    ///      the uint160.max headroom threshold, the token is re-approved (zero-first, so approve-race tokens
    ///      don't revert the heal) instead of the operation bricking on the Permit2 pull.
    function test_add_reapprovesDegradedAllowance() public {
        MockERC20ApproveRace token = new MockERC20ApproveRace();
        token.mint(address(this), 1_000e18);
        token.approve(address(permit2), type(uint256).max);
        permit2.approve(address(token), address(zap), type(uint160).max, type(uint48).max);
        token.approve(address(modifyLiquidityRouter), type(uint256).max);
        PoolKey memory k = _initWeirdTokenPool(address(token));

        ISwapAndAdd.AddParams memory p = _addParams(0, 5e18);
        p.poolKey = k;
        zap.add(p); // wires the token: allowance(zap -> permit2) = uint256.max
        assertEq(token.allowance(address(zap), address(permit2)), type(uint256).max, "wired to max");

        // degrade the allowance below any possible Permit2 pull — nonzero, so a heal that isn't
        // zero-first would trip the approve race and revert
        token.setAllowance(address(zap), address(permit2), 1e18);

        (, uint128 liq,,) = zap.add(p);

        assertGt(liq, 0, "add succeeded after self-heal");
        assertEq(token.allowance(address(zap), address(permit2)), type(uint256).max, "allowance healed to max");
    }

    /// @dev Extreme-tick sizing regressions: narrow range with the price on its lower edge -> single-sided
    ///      token0, no swap, no fee — the minted liquidity must be the full budget's worth. Pre-fix, the 1e18
    ///      reference position's sub-wei amounts rounded up (high ticks, ~1% deployed) and the token1-per-token0
    ///      rate truncated to zero (ticks <~ -665455, revert / budget ignored).
    function test_add_extremeHighTick_fullDeployment() public {
        _assertFullDeploymentAtTick(800000, 2e13);
    }

    function test_add_extremeLowTick_fullDeployment() public {
        _assertFullDeploymentAtTick(-700000, 1e30);
    }

    /// @dev In-range two-sided add at price << 1: exercises the inverse-rate (token0 numeraire) valuation of a
    ///      token1 budget. Deeper ticks are pinned single-sided above — below ~-665k one wei of token1 outweighs
    ///      any realistic token0 budget, so two-sided adds there are not physically meaningful.
    function test_add_lowTick_inRange_valuesToken1ViaInverseRate() public {
        int24 tick = -400000;
        PoolKey memory k = _initTickPool(tick);
        uint160 sp = TickMath.getSqrtPriceAtTick(tick);
        uint160 sl = TickMath.getSqrtPriceAtTick(tick - 600);
        uint160 su = TickMath.getSqrtPriceAtTick(tick + 600);
        // in-ratio budgets for ~1e18 liquidity; the token1 side carries half the value through the inverse rate
        uint256 b0 = SqrtPriceMath.getAmount0Delta(sp, su, 1e18, false);
        uint256 b1 = SqrtPriceMath.getAmount1Delta(sl, sp, 1e18, false);
        MockERC20(Currency.unwrap(currency0)).mint(address(this), b0);
        MockERC20(Currency.unwrap(currency1)).mint(address(this), b1);
        uint128 expected = LiquidityAmounts.getLiquidityForAmounts(sp, sl, su, b0, b1);

        ISwapAndAdd.AddParams memory p = _addParams(tick - 600, tick + 600, b0, b1);
        p.poolKey = k;
        (, uint128 liq,,) = zap.add(p);
        assertGe(liq, uint128(uint256(expected) * 999 / 1000), "token1 budget valued at low tick");
    }

    function testFuzz_add_extremeTick_fullDeployment(int24 tick, uint256 exp) public {
        tick = int24((bound(int256(tick), -800000, 799990) / 10) * 10);
        uint256 b0 = 10 ** bound(exp, 6, 30);
        uint160 spl = TickMath.getSqrtPriceAtTick(tick);
        uint160 spu = TickMath.getSqrtPriceAtTick(tick + 60);
        // uint256 replica of getLiquidityForAmount0 — the lib itself would SafeCast-revert on oversized combos
        uint256 expected = FullMath.mulDiv(b0, FullMath.mulDiv(spl, spu, FixedPoint96.Q96), spu - spl);
        // meaningful size, under the per-tick liquidity cap for spacing 10
        vm.assume(expected >= 1e6 && expected < 1e33);
        _assertFullDeploymentAtTick(tick, b0);
    }

    function _initTickPool(int24 tick) internal returns (PoolKey memory k) {
        k = PoolKey({currency0: currency0, currency1: currency1, fee: 3000, tickSpacing: 10, hooks: IHooks(address(0))});
        manager.initialize(k, TickMath.getSqrtPriceAtTick(tick));
    }

    function _assertFullDeploymentAtTick(int24 tick, uint256 b0) internal {
        PoolKey memory k = _initTickPool(tick);
        MockERC20(Currency.unwrap(currency0)).mint(address(this), b0);
        uint128 expected = LiquidityAmounts.getLiquidityForAmount0(
            TickMath.getSqrtPriceAtTick(tick), TickMath.getSqrtPriceAtTick(tick + 60), b0
        );
        ISwapAndAdd.AddParams memory p = _addParams(tick, tick + 60, b0, 0);
        p.poolKey = k;
        p.minLiquidity = uint256(expected) * 999 / 1000; // contract-enforced floor: >= 99.9% of feasible
        (, uint128 liq,,) = zap.add(p);
        assertGe(liq, uint128(p.minLiquidity), "full budget deployed at extreme tick");
    }

    /// @dev Land the pool price EXACTLY on `boundaryTick`'s sqrtPrice via a limit-clamped swap, and return the
    ///      boundary price. Going down (zeroForOne) the pool stores tick = boundary - 1; going up, tick = boundary.
    function _swapToExactBoundary(int24 boundaryTick, bool zeroForOne) internal returns (uint160 boundary) {
        boundary = TickMath.getSqrtPriceAtTick(boundaryTick);
        swapRouter.swap(
            key,
            SwapParams({zeroForOne: zeroForOne, amountSpecified: -100_000e18, sqrtPriceLimitX96: boundary}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    /// @dev The pool selects its amounts branch by TICK while the zap selects by SQRTPRICE. The one state where
    ///      they disagree: price exactly on an initialized boundary after a zeroForOne swap (pool stores
    ///      tick = boundary - 1, price = sqrtPriceAtTick(boundary)). Minting a range whose UPPER edge is that
    ///      boundary: the zap's price-branch computes single-sided token1 (amount0 = 0) while the pool's
    ///      tick-branch computes in-range — the in-range amount0 must degenerate to exactly 0, else POSM pulls
    ///      token0 the zap never funded and the unlock reverts (CurrencyNotSettled).
    function test_add_priceExactlyOnUpperBoundary_tickBelow() public {
        zap.add(_addParams(1e18, 1e18)); // initialize ticks ±600 so the swap lands ON an initialized boundary
        uint160 boundary = _swapToExactBoundary(-600, true);

        (uint160 sp, int24 tick,,) = manager.getSlot0(key.toId());
        assertEq(sp, boundary, "engineered state: price exactly on the -600 boundary");
        assertEq(tick, -601, "engineered state: stored tick on the other side of the boundary");

        (uint256 tokenId, uint128 liq,,) = zap.add(_addParams(-1200, -600, 0, 5e18));

        assertEq(IERC721(address(lpm)).ownerOf(tokenId), address(this), "user owns NFT");
        assertGt(liq, 0, "liquidity minted at the inconsistent boundary");
        assertEq(currency0.balanceOf(address(zap)), 0, "zap token0 == 0");
        assertEq(currency1.balanceOf(address(zap)), 0, "zap token1 == 0");
    }

    /// @dev Mirror case at a range's LOWER edge: price exactly on the boundary with tick == boundary (oneForZero
    ///      landing). The zap's price-branch (<=) computes single-sided token0; the pool's tick-branch computes
    ///      in-range — its amount1 must degenerate to exactly 0.
    function test_add_priceExactlyOnLowerBoundary_tickAt() public {
        zap.add(_addParams(1e18, 1e18));
        uint160 boundary = _swapToExactBoundary(600, false);

        (uint160 sp, int24 tick,,) = manager.getSlot0(key.toId());
        assertEq(sp, boundary, "engineered state: price exactly on the 600 boundary");
        assertEq(tick, 600, "engineered state: tick at the boundary");

        // the boundary swap bought ALL token0 out of the PoolManager (every seeded position is 100% token1 at
        // the boundary); the sizing round-up's wei-level flash-take needs PM-wide token0 reserves to exist.
        modifyLiquidityRouter.modifyLiquidity(
            key, ModifyLiquidityParams({tickLower: 600, tickUpper: 1200, liquidityDelta: 100e18, salt: 0}), ""
        );

        (uint256 tokenId, uint128 liq,,) = zap.add(_addParams(600, 1200, 5e18, 0));

        assertEq(IERC721(address(lpm)).ownerOf(tokenId), address(this), "user owns NFT");
        assertGt(liq, 0, "liquidity minted at the boundary");
        assertEq(currency0.balanceOf(address(zap)), 0, "zap token0 == 0");
        assertEq(currency1.balanceOf(address(zap)), 0, "zap token1 == 0");
    }

    function _thinPool() internal returns (PoolKey memory thin) {
        (thin,) = initPool(currency0, currency1, IHooks(address(0)), 500, SQRT_PRICE_1_1);
        modifyLiquidityRouter.modifyLiquidity(
            thin, ModifyLiquidityParams({tickLower: -6000, tickUpper: 6000, liquidityDelta: 1e15, salt: 0}), ""
        );
    }
}
