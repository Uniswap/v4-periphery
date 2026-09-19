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
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {IERC721} from "forge-std/interfaces/IERC721.sol";

import {PosmTestSetup} from "./shared/PosmTestSetup.sol";
import {Actions} from "../src/libraries/Actions.sol";
import {LiquidityAmounts} from "../src/libraries/LiquidityAmounts.sol";
import {PositionConfig} from "./shared/PositionConfig.sol";
import {MockSwapRoute} from "./mocks/MockSwapRoute.sol";
import {MockERC20ApproveNoReturn} from "./mocks/MockERC20ApproveNoReturn.sol";
import {MockERC20Permit2Native} from "./mocks/MockERC20Permit2Native.sol";
import {MockERC20ApproveRace} from "./mocks/MockERC20ApproveRace.sol";
import {MockDynamicFeeHook} from "./mocks/MockDynamicFeeHook.sol";
import {ISwapAndAdd} from "../src/interfaces/ISwapAndAdd.sol";
import {IUniversalRouter} from "../src/interfaces/external/IUniversalRouter.sol";

/// @notice SwapAndAdd tests. Empty-route cases exercise the same-pool path, routed cases drive a
///         MockSwapRoute. End-to-end tests against the real Universal Router live in test-integration/.
contract SwapAndAddTest is PosmTestSetup {
    using StateLibrary for IPoolManager;
    using CurrencyLibrary for Currency;

    ISwapAndAdd zap;
    MockSwapRoute route;
    int24 constant TICK_LOWER = -600;
    int24 constant TICK_UPPER = 600;
    /// @dev A non-empty route payload. The mock ignores its content.
    bytes constant ROUTE_PAYLOAD = abi.encode(bytes(""), new bytes[](0));

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();
        deployAndApprovePosm(manager);

        (key,) = initPoolAndAddLiquidity(currency0, currency1, IHooks(address(0)), 3000, SQRT_PRICE_1_1);
        seedMoreLiquidity(key, 1_000e18, 1_000e18);

        route = new MockSwapRoute(permit2);
        // Deploy from the precompiled via_ir artifact, so the via_ir=false test build never compiles the source.
        zap = ISwapAndAdd(
            deployCode("SwapAndAdd.sol:SwapAndAdd", abi.encode(manager, permit2, lpm, IUniversalRouter(address(route))))
        );
        // The mock route needs off-venue inventory to deliver the deficit token.
        MockERC20(Currency.unwrap(currency0)).mint(address(route), 1_000_000e18);
        MockERC20(Currency.unwrap(currency1)).mint(address(route), 1_000_000e18);

        seedBalance(address(this));
        _approveZap(currency0);
        _approveZap(currency1);

        // Native pool (currency0 == native ETH) with depth for the native add tests.
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
            routeFunding: new ISwapAndAdd.TokenAmount[](0),
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
        // Dust lands in the input token (token1). The swapped-into token0 returns almost nothing.
        assertApproxEqAbs(currency0.balanceOf(address(this)), c0Before, 5, "no token0 dust to user");
        assertEq(currency0.balanceOf(address(zap)), 0, "zap token0 == 0");
        assertEq(currency1.balanceOf(address(zap)), 0, "zap token1 == 0");
    }

    function test_add_singleToken0() public {
        uint256 amountIn = 10e18;
        uint256 c1Before = currency1.balanceOf(address(this));

        (uint256 tokenId, uint128 liq,,) = zap.add(_addParams(amountIn, 0));

        assertEq(IERC721(address(lpm)).ownerOf(tokenId), address(this), "user owns NFT");
        assertGt(liq, 0, "liquidity minted");
        // Dust lands in the input token (token0). The swapped-into token1 returns almost nothing.
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

    /// @dev Every entrypoint rejects the zap itself as recipient, which keeps no funds at rest.
    function test_revertsWhenRecipientIsZap() public {
        ISwapAndAdd.AddParams memory addParams = _addParams(0, 10e18);
        addParams.recipient = address(zap);
        vm.expectRevert(abi.encodeWithSelector(ISwapAndAdd.InvalidRecipient.selector, address(zap)));
        zap.add(addParams);

        (uint256 tokenId,,,) = zap.add(_addParams(0, 10e18));

        ISwapAndAdd.IncreaseParams memory increaseParams = _increaseParams(tokenId, 0, 10e18);
        increaseParams.recipient = address(zap);
        vm.expectRevert(abi.encodeWithSelector(ISwapAndAdd.InvalidRecipient.selector, address(zap)));
        zap.increase(increaseParams);

        ISwapAndAdd.RebalanceParams memory rebalanceParams = _rebalanceParams(tokenId, 0, 0);
        rebalanceParams.recipient = address(zap);
        vm.expectRevert(abi.encodeWithSelector(ISwapAndAdd.InvalidRecipient.selector, address(zap)));
        zap.rebalance(rebalanceParams);

        ISwapAndAdd.CompoundParams memory compoundParams = _compoundParams(tokenId, 0);
        compoundParams.recipient = address(zap);
        vm.expectRevert(abi.encodeWithSelector(ISwapAndAdd.InvalidRecipient.selector, address(zap)));
        zap.compound(compoundParams);
    }

    /// @dev Every entrypoint rejects the zero address up front, so no sweep can silently burn leftovers.
    function test_revertsWhenRecipientIsZero() public {
        ISwapAndAdd.AddParams memory addParams = _addParams(0, 10e18);
        addParams.recipient = address(0);
        vm.expectRevert(abi.encodeWithSelector(ISwapAndAdd.InvalidRecipient.selector, address(0)));
        zap.add(addParams);

        (uint256 tokenId,,,) = zap.add(_addParams(0, 10e18));

        ISwapAndAdd.IncreaseParams memory increaseParams = _increaseParams(tokenId, 0, 10e18);
        increaseParams.recipient = address(0);
        vm.expectRevert(abi.encodeWithSelector(ISwapAndAdd.InvalidRecipient.selector, address(0)));
        zap.increase(increaseParams);

        ISwapAndAdd.RebalanceParams memory rebalanceParams = _rebalanceParams(tokenId, 0, 0);
        rebalanceParams.recipient = address(0);
        vm.expectRevert(abi.encodeWithSelector(ISwapAndAdd.InvalidRecipient.selector, address(0)));
        zap.rebalance(rebalanceParams);

        ISwapAndAdd.CompoundParams memory compoundParams = _compoundParams(tokenId, 0);
        compoundParams.recipient = address(0);
        vm.expectRevert(abi.encodeWithSelector(ISwapAndAdd.InvalidRecipient.selector, address(0)));
        zap.compound(compoundParams);
    }

    /// @dev receive() accepts native only from known senders, so a stray transfer cannot join a sweep.
    function test_receive_rejectsUnknownSender() public {
        (bool ok,) = address(zap).call{value: 1 ether}("");
        assertFalse(ok, "direct native transfer must revert");

        vm.prank(address(manager));
        (bool okPm,) = address(zap).call{value: 1 ether}("");
        assertTrue(okPm, "PoolManager may send native");
    }

    // increase (grow an existing position)

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

    /// @dev Increase grows the same tokenId in place, no new NFT.
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

    /// @dev Decreases a position to 0 via POSM and keeps the NFT.
    function _emptyPosition(uint256 tokenId) internal {
        bytes memory actions = abi.encodePacked(uint8(Actions.DECREASE_LIQUIDITY), uint8(Actions.TAKE_PAIR));
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(tokenId, uint256(lpm.getPositionLiquidity(tokenId)), uint128(0), uint128(0), bytes(""));
        params[1] = abi.encode(key.currency0, key.currency1, address(this));
        lpm.modifyLiquidities(abi.encode(actions, params), block.timestamp + 1);
        assertEq(lpm.getPositionLiquidity(tokenId), 0, "position emptied");
    }

    /// @dev An emptied position (0 liquidity, NFT alive) is refillable through increase.
    function test_increase_worksOnEmptiedPosition() public {
        (uint256 tokenId,,,) = zap.add(_addParams(0, 10e18));
        IERC721(address(lpm)).setApprovalForAll(address(zap), true);
        _emptyPosition(tokenId);

        (uint128 added,,) = zap.increase(_increaseParams(tokenId, 0, 5e18));

        assertGt(added, 0, "empty position refilled");
        assertEq(lpm.getPositionLiquidity(tokenId), added, "position liquidity equals added");
    }

    /// @dev Compound on an emptied position surfaces NoFeesToCompound, not an opaque v4 error.
    function test_compound_emptiedPosition_revertsNoFees() public {
        (uint256 tokenId,,,) = zap.add(_addParams(0, 10e18));
        IERC721(address(lpm)).setApprovalForAll(address(zap), true);
        _emptyPosition(tokenId);

        vm.expectRevert(ISwapAndAdd.NoFeesToCompound.selector);
        zap.compound(_compoundParams(tokenId, 0));
    }

    function test_increase_revertsOnMinLiquidity() public {
        (uint256 tokenId,,,) = zap.add(_addParams(0, 10e18));
        IERC721(address(lpm)).setApprovalForAll(address(zap), true);
        ISwapAndAdd.IncreaseParams memory p = _increaseParams(tokenId, 0, 10e18);
        p.minLiquidityAdded = type(uint128).max; // impossible floor
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

    /// @dev An increase collects and spends the position's accrued fees, so caller auth is required.
    function test_increase_revertsIfNotAuthorized() public {
        (uint256 tokenId,,,) = zap.add(_addParams(0, 10e18));
        IERC721(address(lpm)).setApprovalForAll(address(zap), true);
        vm.prank(makeAddr("stranger"));
        vm.expectRevert(abi.encodeWithSelector(ISwapAndAdd.NotAuthorizedForToken.selector, tokenId));
        zap.increase(_increaseParams(tokenId, 0, 1e18));
    }

    /// @dev A zero-budget increase equals a compound.
    function test_increase_zeroBudget_equalsCompound() public {
        (uint256 tokenId,,,) = zap.add(_addParams(0, 10e18));
        IERC721(address(lpm)).setApprovalForAll(address(zap), true);
        _generateFees();

        uint256 snap = vm.snapshotState();
        (uint128 viaCompound,,) = zap.compound(_compoundParams(tokenId, 0));
        vm.revertToState(snap);

        (uint128 viaIncrease,,) = zap.increase(_increaseParams(tokenId, 0, 0));
        assertGt(viaIncrease, 0, "zero-budget increase reinvested the fees");
        assertEq(viaIncrease, viaCompound, "increase(0,0) == compound");
    }

    /// @dev An increase collects and reinvests the position's accrued fees.
    function test_increase_collectsAndReinvestsFees() public {
        (uint256 tokenId, uint128 liq0,,) = zap.add(_addParams(0, 10e18));
        IERC721(address(lpm)).setApprovalForAll(address(zap), true);
        _generateFees();

        (uint128 added,,) = zap.increase(_increaseParams(tokenId, 0, 5e18));

        assertGt(added, 0, "budget + fees deployed");
        assertEq(lpm.getPositionLiquidity(tokenId), liq0 + added, "position grew by exactly the added liquidity");
        // The increase consumed the fees, so an immediate compound finds nothing to reinvest.
        vm.expectRevert(ISwapAndAdd.NoFeesToCompound.selector);
        zap.compound(_compoundParams(tokenId, 0));
    }

    /// @dev An increase with nothing to deploy reverts instead of a silent no-op.
    function test_increase_revertsWhenNothingToDeploy() public {
        (uint256 tokenId,,,) = zap.add(_addParams(0, 10e18));
        IERC721(address(lpm)).setApprovalForAll(address(zap), true);
        vm.expectRevert(ISwapAndAdd.NoFeesToCompound.selector);
        zap.increase(_increaseParams(tokenId, 0, 0));
    }

    /// @dev An operator-called increase forces all swept dust to the owner.
    function test_increase_operatorCannotRedirectDust() public {
        (uint256 tokenId,,,) = zap.add(_addParams(0, 10e18));
        IERC721(address(lpm)).setApprovalForAll(address(zap), true);
        _generateFees();
        address operator = makeAddr("operator");
        IERC721(address(lpm)).setApprovalForAll(operator, true);
        MockERC20(Currency.unwrap(currency1)).mint(operator, 5e18);

        vm.startPrank(operator);
        MockERC20(Currency.unwrap(currency1)).approve(address(permit2), type(uint256).max);
        permit2.approve(Currency.unwrap(currency1), address(zap), type(uint160).max, type(uint48).max);
        ISwapAndAdd.IncreaseParams memory p = _increaseParams(tokenId, 0, 5e18);
        p.recipient = operator; // operator tries to redirect the dust
        zap.increase(p);
        vm.stopPrank();

        assertEq(currency0.balanceOf(operator), 0, "operator got no token0 dust");
        assertEq(currency1.balanceOf(operator), 0, "operator got no token1 dust");
    }

    /// @notice Returned dust is tiny, only the genuine slippage shortfall in the input token.
    function test_add_lowDust() public {
        uint256 amountIn = 10e18;
        uint256 c0Before = currency0.balanceOf(address(this));
        uint256 c1Before = currency1.balanceOf(address(this));

        zap.add(_addParams(0, amountIn));

        // net token1 spent = pulled budget - swept dust
        uint256 dust1 = currency1.balanceOf(address(this)) + amountIn - c1Before;
        // Measured near 15 bps of budget here, so the 2% bound has headroom.
        assertLt(dust1, amountIn / 50, "token1 dust < 2% of budget");
        assertApproxEqAbs(currency0.balanceOf(address(this)), c0Before, 5, "no token0 dust");
        assertEq(currency0.balanceOf(address(zap)), 0, "zap token0 == 0");
        assertEq(currency1.balanceOf(address(zap)), 0, "zap token1 == 0");
    }

    /// @dev A budget too small for one unit of liquidity surfaces InsufficientLiquidity, not an opaque v4 error.
    function test_add_zeroSizedMint_revertsInsufficientLiquidity() public {
        ISwapAndAdd.AddParams memory p = _addParams(-887_220, 887_220, 0, 1); // 1 wei into (nearly) full range
        vm.expectRevert(abi.encodeWithSelector(ISwapAndAdd.InsufficientLiquidity.selector, 0, 0));
        zap.add(p);
    }

    function test_add_revertsOnMinLiquidity() public {
        ISwapAndAdd.AddParams memory p = _addParams(0, 10e18);
        p.minLiquidity = type(uint128).max; // impossible floor
        vm.expectRevert();
        zap.add(p);
    }

    function _rebalanceParams(uint256 tokenId, int128 additional0, int128 additional1)
        internal
        view
        returns (ISwapAndAdd.RebalanceParams memory)
    {
        return ISwapAndAdd.RebalanceParams({
            tokenId: tokenId,
            additional0: additional0,
            additional1: additional1,
            newTickLower: -1200,
            newTickUpper: 1200,
            route: "",
            routeFunding: new ISwapAndAdd.TokenAmount[](0),
            minLiquidity: 0,
            recipient: address(this),
            hookData: "",
            deadline: block.timestamp + 1
        });
    }

    function test_rebalance_full() public {
        (uint256 tokenId,,,) = zap.add(_addParams(0, 10e18));
        IERC721(address(lpm)).setApprovalForAll(address(zap), true);

        // (0, 0) deltas mean a full move, burn the whole position and redeploy everything
        (uint256 newTokenId, uint128 newLiq,,) = zap.rebalance(_rebalanceParams(tokenId, 0, 0));

        assertEq(IERC721(address(lpm)).ownerOf(newTokenId), address(this), "user owns new NFT");
        assertGt(newLiq, 0, "new liquidity minted");
        assertEq(lpm.getPositionLiquidity(tokenId), 0, "old position fully burned");
        assertEq(currency0.balanceOf(address(zap)), 0, "zap token0 == 0");
        assertEq(currency1.balanceOf(address(zap)), 0, "zap token1 == 0");
    }

    /// @dev A negative delta returns token1 to the recipient and redeploys only the remainder.
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

    /// @dev A positive delta pulls more token1 from the wallet, so the new position is larger.
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

    /// @dev Mixed signs pull more token0 and return some token1 in one call.
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
        // request far more token1 than the burned position holds
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
            routeFunding: new ISwapAndAdd.TokenAmount[](0),
            minLiquidity: 0,
            recipient: address(this),
            hookData: "",
            deadline: block.timestamp + 1
        });

        (uint256 tokenId, uint128 liq,,) = zap.add{value: nativeIn}(p);

        assertEq(IERC721(address(lpm)).ownerOf(tokenId), address(this), "user owns NFT");
        assertGt(liq, 0, "liquidity minted");
        // Dust lands in the input token (native). The swapped-into currency1 returns almost nothing.
        assertApproxEqAbs(currency1.balanceOf(address(this)), c1Before, 5, "no token1 dust to user");
        assertEq(address(zap).balance, 0, "zap eth == 0");
        assertEq(currency1.balanceOf(address(zap)), 0, "zap token1 == 0");
    }

    /// @dev Regression: a range below spot needs zero token0, so the native mint must forward zero value.
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

    /// @dev Regression: Slot0's protocolFee packs two directional fees. Sizing must use the direction's swap fee.
    function test_add_directionalProtocolFeeSet() public {
        vm.prank(feeController);
        manager.setProtocolFee(key, uint24((250 << 12) | 250)); // 0.025% both directions, packed

        (uint256 tokenId, uint128 liq,,) = zap.add(_addParams(10e18, 0));
        assertEq(IERC721(address(lpm)).ownerOf(tokenId), address(this), "user owns NFT");
        assertGt(liq, 0, "liquidity minted with directional protocol fee");

        // the other surplus direction
        (, uint128 liq1,,) = zap.add(_addParams(0, 10e18));
        assertGt(liq1, 0, "liquidity minted, token1-surplus direction");
    }

    /// @dev A dynamic fee override is invisible to Slot0 sizing. The trim absorbs the difference and the
    ///      final liquidity floor still holds.
    function test_add_dynamicFeeOverride_forwardsHookDataAndHonorsFinalFloor() public {
        bytes memory hookData = abi.encode("swap-and-add dynamic hook authorization");
        address hookAddress = address(uint160(Hooks.BEFORE_SWAP_FLAG));
        MockDynamicFeeHook implementation = new MockDynamicFeeHook();
        vm.etch(hookAddress, address(implementation).code);
        MockDynamicFeeHook hook = MockDynamicFeeHook(hookAddress);
        hook.configure(hookData, 0);

        (PoolKey memory dynamicKey,) = initPoolAndAddLiquidity(
            currency0, currency1, IHooks(hookAddress), LPFeeLibrary.DYNAMIC_FEE_FLAG, SQRT_PRICE_1_1
        );
        seedMoreLiquidity(dynamicKey, 1_000e18, 1_000e18);

        ISwapAndAdd.AddParams memory p = _addParams(10e18, 0);
        p.poolKey = dynamicKey;
        p.hookData = hookData;

        uint256 baselineSnapshot = vm.snapshotState();
        (, uint128 zeroFeeLiquidity,,) = zap.add(p);
        assertGt(hook.beforeSwapCalls(), 0, "reconcile forwarded hookData to beforeSwap");
        vm.revertToState(baselineSnapshot);

        hook.setFee(100_000); // 10% actual fee. Slot0 keeps its stored 0 fee.
        uint256 highFeeSnapshot = vm.snapshotState();
        (, uint128 highFeeLiquidity,,) = zap.add(p);
        assertLt(highFeeLiquidity, zeroFeeLiquidity, "override fee caused a larger trim");
        assertGt(hook.beforeSwapCalls(), 0, "dynamic-fee reconcile swap ran");
        assertEq(currency0.balanceOf(address(zap)), 0, "zap token0 == 0");
        assertEq(currency1.balanceOf(address(zap)), 0, "zap token1 == 0");
        vm.revertToState(highFeeSnapshot);

        p.minLiquidity = zeroFeeLiquidity;
        vm.expectPartialRevert(ISwapAndAdd.InsufficientLiquidity.selector);
        zap.add(p);
    }

    /// @dev Returns-delta hooks break settlement conservation, so the zap rejects them with a typed error.
    function test_add_returnsDeltaHook_revertsUnsupported() public {
        uint160[4] memory flagged = [
            Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG,
            Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG,
            Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.AFTER_ADD_LIQUIDITY_RETURNS_DELTA_FLAG,
            Hooks.AFTER_REMOVE_LIQUIDITY_FLAG | Hooks.AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA_FLAG
        ];
        ISwapAndAdd.AddParams memory p = _addParams(1e18, 1e18);
        for (uint256 i = 0; i < flagged.length; i++) {
            p.poolKey.hooks = IHooks(address(flagged[i]));
            vm.expectRevert(abi.encodeWithSelector(ISwapAndAdd.UnsupportedHookPermissions.selector, p.poolKey.hooks));
            zap.add(p);
        }

        // Negative control: a hook without returns-delta flags passes the gate and fails deeper.
        p.poolKey.hooks = IHooks(address(uint160(Hooks.BEFORE_SWAP_FLAG)));
        vm.expectRevert(IPoolManager.PoolNotInitialized.selector);
        zap.add(p);
    }

    function test_rebalance_revertsIfNotAuthorized() public {
        (uint256 tokenId,,,) = zap.add(_addParams(0, 10e18));
        // stranger, zap not approved
        vm.prank(address(0xBEEF));
        vm.expectRevert();
        zap.rebalance(_rebalanceParams(tokenId, 0, 0));
    }

    /// @dev SECURITY: an approved operator cannot redirect the new NFT or the cash-out away from the owner.
    function test_rebalance_operatorCannotRedirectToSelf() public {
        address operator = address(0xBEEF);
        (uint256 tokenId,,,) = zap.add(_addParams(0, 10e18));
        IERC721(address(lpm)).setApprovalForAll(address(zap), true);
        IERC721(address(lpm)).setApprovalForAll(operator, true);

        ISwapAndAdd.RebalanceParams memory p = _rebalanceParams(tokenId, 0, -1e18); // cash out 1 token1
        p.recipient = operator; // operator tries to redirect the output

        uint256 opC1Before = currency1.balanceOf(operator);
        uint256 ownerC1Before = currency1.balanceOf(address(this));
        vm.prank(operator);
        (uint256 newTokenId,,,) = zap.rebalance(p);

        assertEq(IERC721(address(lpm)).ownerOf(newTokenId), address(this), "new NFT forced to owner, not operator");
        assertEq(currency1.balanceOf(operator), opC1Before, "operator received NO cash-out");
        assertGe(currency1.balanceOf(address(this)) - ownerC1Before, 1e18, "owner received the cash-out");
    }

    /// @dev The owner can still direct the output to any address.
    function test_rebalance_ownerMayChooseRecipient() public {
        address dest = address(0xCAFE);
        (uint256 tokenId,,,) = zap.add(_addParams(0, 10e18));
        IERC721(address(lpm)).setApprovalForAll(address(zap), true);

        ISwapAndAdd.RebalanceParams memory p = _rebalanceParams(tokenId, 0, 0);
        p.recipient = dest;
        (uint256 newTokenId,,,) = zap.rebalance(p); // owner is msg.sender

        assertEq(IERC721(address(lpm)).ownerOf(newTokenId), dest, "owner may send the new NFT to a chosen recipient");
    }

    // routed (route-first) cases

    /// @dev Configure the mock route: consume `inputAmount` of token1 and return token0 at `rateMultBps`
    ///      against the 1:1 mid (10000 = mid).
    function _configRoute(uint256 rateMultBps, uint256 inputAmount) internal {
        route.config(
            Currency.unwrap(currency1), Currency.unwrap(currency0), FixedPoint96.Q96, rateMultBps, inputAmount, false
        );
    }

    function _routeAdd(uint256 amount1In) internal view returns (ISwapAndAdd.AddParams memory p) {
        p = _addParams(0, amount1In);
        p.route = ROUTE_PAYLOAD;
    }

    /// @dev UR balances are permissionlessly sweepable, so the SWEEP reclaim must fire whenever the router
    ///      holds native. The whole balance joins the caller's budget.
    function test_add_route_reclaimsAnyUrNative() public {
        _configRoute(10000, 0); // no-op route, consumes nothing
        ISwapAndAdd.AddParams memory p = _routeAdd(10e18);
        p.poolKey = nativeKey;

        // 1) No value pushed: a native balance in the UR is still reclaimed into the budget.
        uint256 snap = vm.snapshotState();
        (, uint128 liqBaseNoPush,,) = zap.add(p); // no donation in the UR
        vm.revertToState(snap);

        vm.deal(address(route), 1 ether); // stranded native sitting in the UR
        (, uint128 liqDonatedNoPush,,) = zap.add(p);
        assertEq(address(route).balance, 0, "no push: UR native still fully reclaimed");
        assertEq(address(zap).balance, 0, "zap eth == 0");
        assertGt(liqDonatedNoPush, liqBaseNoPush, "reclaimed UR native joined the caller's budget");

        // 2) Value pushed: the unconsumed push and the donation are both reclaimed.
        p.amount0In = 2 ether;
        snap = vm.snapshotState();
        (, uint128 liqBase,,) = zap.add{value: 2 ether}(p);
        vm.revertToState(snap);

        vm.deal(address(route), 1 ether);
        (, uint128 liqDonated,,) = zap.add{value: 2 ether}(p);
        assertEq(address(route).balance, 0, "value pushed: UR native fully reclaimed");
        assertEq(address(zap).balance, 0, "zap eth == 0");
        assertGt(liqDonated, liqBase, "reclaimed donation joined the caller's budget");
    }

    /// @notice The route under-converts, so the same-pool reconcile fills the remaining deficit.
    function test_add_route_underConverts() public {
        _configRoute(9970, 3e18); // ~mid-0.3%, under the ~5e18 ideal for a 10e18 single-token1 budget
        (uint256 tokenId, uint128 liq,,) = zap.add(_routeAdd(10e18));
        assertEq(IERC721(address(lpm)).ownerOf(tokenId), address(this), "user owns NFT");
        assertGt(liq, 0, "liquidity minted");
        assertEq(currency0.balanceOf(address(zap)), 0, "zap token0 == 0");
        assertEq(currency1.balanceOf(address(zap)), 0, "zap token1 == 0");
    }

    /// @notice The route over-converts, so the reconcile sells the excess token0 back to token1.
    function test_add_route_overConverts() public {
        _configRoute(9970, 7e18); // over the ~5e18 ideal, ends long token0
        (uint256 tokenId, uint128 liq,,) = zap.add(_routeAdd(10e18));
        assertEq(IERC721(address(lpm)).ownerOf(tokenId), address(this), "user owns NFT");
        assertGt(liq, 0, "liquidity minted");
        assertEq(currency0.balanceOf(address(zap)), 0, "zap token0 == 0");
        assertEq(currency1.balanceOf(address(zap)), 0, "zap token1 == 0");
    }

    /// @notice A better-than-mid route deploys more liquidity than the same-pool path.
    function test_add_route_betterThanMid_capturesUpside() public {
        uint256 snap = vm.snapshotState();
        (, uint128 samePoolLiq,,) = zap.add(_addParams(0, 10e18)); // same-pool baseline
        vm.revertToState(snap);

        _configRoute(10200, 5e18); // route beats mid by 2%
        (, uint128 routedLiq,,) = zap.add(_routeAdd(10e18));
        assertGt(routedLiq, samePoolLiq, "better-than-mid route deploys MORE than same-pool");
    }

    /// @notice A route cheaper than the pool fee deploys more and returns less than the same-pool path.
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

    // failure / edge cases

    function test_add_revertsAfterDeadline() public {
        ISwapAndAdd.AddParams memory p = _addParams(0, 10e18);
        vm.warp(p.deadline + 1);
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
            routeFunding: new ISwapAndAdd.TokenAmount[](0),
            minLiquidity: 0,
            recipient: address(this),
            hookData: "",
            deadline: block.timestamp + 1
        });
        // msg.value != amount0In
        vm.expectRevert(ISwapAndAdd.InvalidEthValue.selector);
        zap.add{value: 1e17 - 1}(p);
    }

    /// @notice minLiquidity one wei above the realized liquidity makes the floor check revert.
    function test_add_revertsWhenTrimUndercutsFloor() public {
        ISwapAndAdd.AddParams memory p = _addParams(0, 10e18);
        uint256 snap = vm.snapshotState();
        (, uint128 liq,,) = zap.add(p); // measure the realized liquidity
        vm.revertToState(snap); // identical re-run
        p.minLiquidity = liq + 1;
        vm.expectRevert(abi.encodeWithSelector(ISwapAndAdd.InsufficientLiquidity.selector, liq + 1, liq));
        zap.add(p);
    }

    // native-ETH rebalance (signed deltas)

    function _nativeAdd(uint256 nativeIn) internal returns (uint256 tokenId) {
        ISwapAndAdd.AddParams memory p = _addParams(nativeIn, 0);
        p.poolKey = nativeKey;
        (tokenId,,,) = zap.add{value: nativeIn}(p);
    }

    /// @dev A positive native delta adds more ETH via msg.value during a rebalance.
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
        // msg.value one wei short of the positive native delta
        vm.expectRevert(ISwapAndAdd.InvalidEthValue.selector);
        zap.rebalance{value: 1e17 - 1}(_rebalanceParams(tokenId, 1e17, 0));
    }

    // compound (reinvest fees)

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

    /// @dev Accrue fees on both sides via balanced round-trip swaps.
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
        // Only swept dust reaches the wallet, the fees were reinvested.
        assertLt(currency0.balanceOf(address(this)) - c0Before, a0 + 1, "token0 fees compounded, not paid out");
        assertLt(currency1.balanceOf(address(this)) - c1Before, a1 + 1, "token1 fees compounded, not paid out");
        assertEq(currency0.balanceOf(address(zap)), 0, "zap token0 == 0");
        assertEq(currency1.balanceOf(address(zap)), 0, "zap token1 == 0");
    }

    function test_compound_revertsOnMinLiquidity() public {
        (uint256 tokenId,,,) = zap.add(_addParams(0, 10e18));
        IERC721(address(lpm)).setApprovalForAll(address(zap), true);
        _generateFees();
        vm.expectRevert(); // impossible floor
        zap.compound(_compoundParams(tokenId, type(uint128).max));
    }

    function test_compound_revertsIfNotAuthorized() public {
        (uint256 tokenId,,,) = zap.add(_addParams(0, 10e18));
        _generateFees();
        vm.prank(address(0xBEEF)); // stranger, zap not approved
        vm.expectRevert();
        zap.compound(_compoundParams(tokenId, 0));
    }

    /// @dev Mint directly with no swaps, so the position genuinely has zero fees.
    function test_compound_revertsWhenNoFees() public {
        uint256 tokenId = lpm.nextTokenId();
        PositionConfig memory cfg = PositionConfig({poolKey: key, tickLower: TICK_LOWER, tickUpper: TICK_UPPER});
        mint(cfg, 1e18, address(this), "");
        IERC721(address(lpm)).setApprovalForAll(address(zap), true);
        vm.expectRevert(ISwapAndAdd.NoFeesToCompound.selector);
        zap.compound(_compoundParams(tokenId, 0));
    }

    /// @dev SECURITY: an approved operator cannot redirect even the swept dust away from the owner.
    function test_compound_operatorCannotRedirectDust() public {
        address operator = address(0xBEEF);
        (uint256 tokenId,,,) = zap.add(_addParams(0, 10e18));
        IERC721(address(lpm)).setApprovalForAll(address(zap), true);
        IERC721(address(lpm)).setApprovalForAll(operator, true);
        _generateFees();

        ISwapAndAdd.CompoundParams memory p = _compoundParams(tokenId, 0);
        p.recipient = operator; // operator tries to grab the dust

        uint256 opC0Before = currency0.balanceOf(operator);
        uint256 opC1Before = currency1.balanceOf(operator);
        vm.prank(operator);
        zap.compound(p);

        assertEq(IERC721(address(lpm)).ownerOf(tokenId), address(this), "NFT stays with owner");
        assertEq(currency0.balanceOf(operator), opC0Before, "operator got no token0 dust");
        assertEq(currency1.balanceOf(operator), opC1Before, "operator got no token1 dust");
    }

    /// @dev Compound may route the collected fees. A dry-run sizes the route input.
    function test_compound_withRoute() public {
        (uint256 tokenId, uint128 liq0,,) = zap.add(_addParams(0, 10e18));
        IERC721(address(lpm)).setApprovalForAll(address(zap), true);
        _generateFees();

        uint256 snap = vm.snapshotState();
        (,, uint256 a1Base) = zap.compound(_compoundParams(tokenId, 0));
        vm.revertToState(snap);

        _configRoute(10100, a1Base / 2); // Convert half the token1 fees at mid+1%.
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

    // sizing / reconcile extremes

    /// @dev ERC-20 counterpart of the native below-range case.
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

    /// @dev Below-spot range funded with token0 only, so the reconcile sell starts from a price above the range.
    function test_add_belowRange_singleToken0() public {
        ISwapAndAdd.AddParams memory p = _addParams(-1200, -660, 10e18, 0);
        (uint256 tokenId, uint128 liq,,) = zap.add(p);
        assertEq(IERC721(address(lpm)).ownerOf(tokenId), address(this), "user owns NFT");
        assertGt(liq, 0, "liquidity minted");
        assertEq(currency0.balanceOf(address(zap)), 0, "zap token0 == 0");
        assertEq(currency1.balanceOf(address(zap)), 0, "zap token1 == 0");
    }

    /// @dev A one-sided budget larger than the pool's external depth pushes the price below the new range,
    ///      and the operation still lands.
    function test_add_narrowRange_hugeSingleSided() public {
        (uint256 tokenId, uint128 liq,,) = zap.add(_addParams(-60, 60, 1_500e18, 0));
        assertEq(IERC721(address(lpm)).ownerOf(tokenId), address(this), "user owns NFT");
        assertGt(liq, 0, "liquidity minted");
        assertEq(currency0.balanceOf(address(zap)), 0, "zap token0 == 0");
        assertEq(currency1.balanceOf(address(zap)), 0, "zap token1 == 0");
    }

    /// @dev Thin pool, huge one-sided budget: the reconcile traverses more depth than exists outside the position.
    function test_add_thinPool_hugeSingleSided() public {
        PoolKey memory thin = _thinPool();
        ISwapAndAdd.AddParams memory p = _addParams(-60, 60, 500e18, 0);
        p.poolKey = thin;
        (, uint128 liq,,) = zap.add(p);
        assertGt(liq, 0, "liquidity minted on thin pool");
        assertEq(currency0.balanceOf(address(zap)), 0, "zap token0 == 0");
        assertEq(currency1.balanceOf(address(zap)), 0, "zap token1 == 0");
    }

    /// @dev Spot at the range's upper edge with a token0-only budget: the reconcile sell must fund the whole mint.
    function test_add_thinPool_priceAtUpperEdge_token0Only() public {
        PoolKey memory thin = _thinPool();
        ISwapAndAdd.AddParams memory p = _addParams(-600, 0, 200e18, 0); // tickUpper == current tick
        p.poolKey = thin;
        (, uint128 liq,,) = zap.add(p);
        assertGt(liq, 0, "liquidity minted at upper edge");
        assertEq(currency0.balanceOf(address(zap)), 0, "zap token0 == 0");
        assertEq(currency1.balanceOf(address(zap)), 0, "zap token1 == 0");
    }

    /// @dev Any two-sided budget must land, including the both-sides-short round-up knife-edge.
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

    /// @dev Initialize a native-ETH/token pool with depth for the weird-token `_ensureApproved` regressions.
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

    /// @dev Regression: `_ensureApproved` must tolerate approve() with no return data (USDT-style).
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

    /// @dev Regression: a Permit2-native token reverts approve() toward Permit2, so `_ensureApproved` must
    ///      skip that call and still grant the Permit2-internal allowances.
    function test_add_permit2NativeToken() public {
        MockERC20Permit2Native token = new MockERC20Permit2Native(address(permit2));
        token.mint(address(this), 1_000e18);
        // The token hardcodes the Permit2 allowance, so no token.approve(permit2) call.
        permit2.approve(address(token), address(zap), type(uint160).max, type(uint48).max);
        token.approve(address(modifyLiquidityRouter), type(uint256).max);
        PoolKey memory k = _initWeirdTokenPool(address(token));

        ISwapAndAdd.AddParams memory p = _addParams(0, 5e18);
        p.poolKey = k;
        (uint256 tokenId, uint128 liq,,) = zap.add(p);

        assertEq(IERC721(address(lpm)).ownerOf(tokenId), address(this), "user owns NFT");
        assertGt(liq, 0, "liquidity minted on permit2-native token pool");
        // The wiring granted the Permit2 allowances without the ERC20 approve.
        (uint160 posmAmount,,) = permit2.allowance(address(zap), address(token), address(lpm));
        (uint160 urAmount,,) = permit2.allowance(address(zap), address(token), address(route));
        assertEq(posmAmount, type(uint160).max, "POSM permit2 allowance granted");
        assertEq(urAmount, type(uint160).max, "UR permit2 allowance granted");

        // Steady state: a second add never touches the token's approve again.
        (, liq,,) = zap.add(p);
        assertGt(liq, 0, "second add on already-wired token");
    }

    /// @dev No pool with native as currency1 can exist. A key that smuggles it in must revert and
    ///      unwind atomically.
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

    /// @dev Regression: a degraded ERC20 allowance to Permit2 is re-approved zero-first, so approve-race
    ///      tokens do not revert the heal.
    function test_add_reapprovesDegradedAllowance() public {
        MockERC20ApproveRace token = new MockERC20ApproveRace();
        token.mint(address(this), 1_000e18);
        token.approve(address(permit2), type(uint256).max);
        permit2.approve(address(token), address(zap), type(uint160).max, type(uint48).max);
        token.approve(address(modifyLiquidityRouter), type(uint256).max);
        PoolKey memory k = _initWeirdTokenPool(address(token));

        ISwapAndAdd.AddParams memory p = _addParams(0, 5e18);
        p.poolKey = k;
        zap.add(p); // wires the token to the max allowance
        assertEq(token.allowance(address(zap), address(permit2)), type(uint256).max, "wired to max");

        // Degrade to a nonzero value, so a heal that is not zero-first trips the approve race.
        token.setAllowance(address(zap), address(permit2), 1e18);

        (, uint128 liq,,) = zap.add(p);

        assertGt(liq, 0, "add succeeded after self-heal");
        assertEq(token.allowance(address(zap), address(permit2)), type(uint256).max, "allowance healed to max");
    }

    /// @dev Extreme-tick regressions: a single-sided token0 range with no swap must deploy the full
    ///      budget's worth of liquidity.
    function test_add_extremeHighTick_fullDeployment() public {
        _assertFullDeploymentAtTick(800000, 2e13);
    }

    function test_add_extremeLowTick_fullDeployment() public {
        _assertFullDeploymentAtTick(-700000, 1e30);
    }

    /// @dev In-range two-sided add at price << 1 exercises the inverse-rate valuation of the token1 budget.
    ///      Below tick ~-665k one wei of token1 outweighs any realistic token0 budget.
    function test_add_lowTick_inRange_valuesToken1ViaInverseRate() public {
        int24 tick = -400000;
        PoolKey memory k = _initTickPool(tick);
        uint160 sp = TickMath.getSqrtPriceAtTick(tick);
        uint160 sl = TickMath.getSqrtPriceAtTick(tick - 600);
        uint160 su = TickMath.getSqrtPriceAtTick(tick + 600);
        // in-ratio budgets for ~1e18 liquidity
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
        // uint256 replica of getLiquidityForAmount0, which SafeCast-reverts on oversized combos
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
        p.minLiquidity = uint256(expected) * 999 / 1000; // floor at 99.9% of feasible
        (, uint128 liq,,) = zap.add(p);
        assertGe(liq, uint128(p.minLiquidity), "full budget deployed at extreme tick");
    }

    /// @dev Land the price exactly on `boundaryTick` via a limit-clamped swap. A zeroForOne swap stores
    ///      tick = boundary - 1, a oneForZero swap stores tick = boundary.
    function _swapToExactBoundary(int24 boundaryTick, bool zeroForOne) internal returns (uint160 boundary) {
        boundary = TickMath.getSqrtPriceAtTick(boundaryTick);
        swapRouter.swap(
            key,
            SwapParams({zeroForOne: zeroForOne, amountSpecified: -100_000e18, sqrtPriceLimitX96: boundary}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    /// @dev The zap sizes by sqrtPrice while the pool branches by tick. With the price exactly on the range's
    ///      upper boundary and the tick below it, the pool's in-range amount0 must degenerate to exactly 0.
    function test_add_priceExactlyOnUpperBoundary_tickBelow() public {
        zap.add(_addParams(1e18, 1e18)); // initialize ticks ±600 as swap landing boundaries
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

    /// @dev Mirror case at the range's lower edge with tick == boundary. The pool's in-range amount1 must
    ///      degenerate to exactly 0.
    function test_add_priceExactlyOnLowerBoundary_tickAt() public {
        zap.add(_addParams(1e18, 1e18));
        uint160 boundary = _swapToExactBoundary(600, false);

        (uint160 sp, int24 tick,,) = manager.getSlot0(key.toId());
        assertEq(sp, boundary, "engineered state: price exactly on the 600 boundary");
        assertEq(tick, 600, "engineered state: tick at the boundary");

        // The boundary swap drained the PoolManager's token0, so seed reserves for the wei-level flash-take.
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
