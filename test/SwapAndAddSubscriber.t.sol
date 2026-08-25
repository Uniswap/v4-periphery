// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {IERC721} from "forge-std/interfaces/IERC721.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {ISwapAndAdd} from "../src/interfaces/ISwapAndAdd.sol";
import {ISubscriber} from "../src/interfaces/ISubscriber.sol";
import {IPositionManager} from "../src/interfaces/IPositionManager.sol";
import {IUniversalRouter} from "../src/interfaces/external/IUniversalRouter.sol";
import {PositionInfo} from "../src/libraries/PositionInfoLibrary.sol";
import {PositionConfig} from "./shared/PositionConfig.sol";
import {PosmTestSetup} from "./shared/PosmTestSetup.sol";
import {MockSubscriber} from "./mocks/MockSubscriber.sol";
import {MockRevertSubscriber} from "./mocks/MockBadSubscribers.sol";
import {MockBurnRevertingSubscriber} from "./mocks/MockBurnRevertingSubscriber.sol";

interface IERC20Min {
    function transfer(address to, uint256 amt) external returns (bool);
}

/// @notice A subscriber that trades the position's own pool from inside a notification — the strongest thing
///         subscriber code can do to a SwapAndAdd operation. It fires on the FIRST notifyModifyLiquidity (the
///         grow ops' fee collect), i.e. between the collect and the sizing read, and settles its own deltas.
contract MockSwappingSubscriber is ISubscriber {
    using CurrencyLibrary for Currency;

    IPositionManager immutable posm;
    IPoolManager immutable manager;
    PoolKey key;
    uint256 swapAmount;
    bool public swapped;

    constructor(IPositionManager _posm, IPoolManager _manager) {
        posm = _posm;
        manager = _manager;
    }

    function config(PoolKey memory k, uint256 amt) external {
        key = k;
        swapAmount = amt;
    }

    function notifySubscribe(uint256, bytes memory) external {}
    function notifyUnsubscribe(uint256) external {}
    function notifyBurn(uint256, address, PositionInfo, uint256, BalanceDelta) external {}

    function notifyModifyLiquidity(uint256, int256, BalanceDelta) external {
        require(msg.sender == address(posm), "not posm");
        if (swapped || swapAmount == 0) return;
        swapped = true;

        BalanceDelta d = manager.swap(
            key,
            SwapParams({
                zeroForOne: true, amountSpecified: -int256(swapAmount), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            ""
        );
        manager.sync(key.currency0);
        IERC20Min(Currency.unwrap(key.currency0)).transfer(address(manager), uint256(uint128(-d.amount0())));
        manager.settle();
        manager.take(key.currency1, address(this), uint256(uint128(d.amount1())));
    }
}

/// @notice POSM SUBSCRIBERS are the one owner-chosen external-call surface inside SwapAndAdd's unlock that is
///         not a hook: `notifyModifyLiquidity` fires (full gas, revert bubbling) on the grow ops' fee collect,
///         the INCREASE, and any trim; `notifyBurn` fires on the rebalance burn. This suite pins the doctrine:
///         a well-behaved subscriber is transparent; a reverting subscriber can only DoS its OWN position's
///         operations (atomic revert, funds safe); a subscriber that trades the pool mid-operation is gated by
///         the `minLiquidity` floor exactly like a hook or the caller's own route.
contract SwapAndAddSubscriberTest is PosmTestSetup {
    using StateLibrary for IPoolManager;
    using CurrencyLibrary for Currency;

    ISwapAndAdd zap;
    MockSubscriber sub;

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();
        deployAndApprovePosm(manager);

        (key,) = initPool(currency0, currency1, IHooks(address(0)), 3000, int24(60), SQRT_PRICE_1_1);
        modifyLiquidityRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({tickLower: -600_000, tickUpper: 600_000, liquidityDelta: int256(1e24), salt: 0}),
            ""
        );

        zap = ISwapAndAdd(
            deployCode("SwapAndAdd.sol:SwapAndAdd", abi.encode(manager, permit2, lpm, IUniversalRouter(makeAddr("ur"))))
        );
        permit2.approve(Currency.unwrap(currency0), address(zap), type(uint160).max, type(uint48).max);
        permit2.approve(Currency.unwrap(currency1), address(zap), type(uint160).max, type(uint48).max);
        IERC721(address(lpm)).setApprovalForAll(address(zap), true);

        sub = new MockSubscriber(lpm);
    }

    // ─────────────────────────────── helpers ───────────────────────────────

    /// @dev Position owned by this contract with accrued fees, subscribed to `subscriber`.
    function _subscribedPosition(address subscriber) internal returns (uint256 tokenId) {
        tokenId = lpm.nextTokenId();
        mint(PositionConfig({poolKey: key, tickLower: -600, tickUpper: 600}), 1e21, address(this), "");
        // accrue fees so the grow ops have position value to work with
        swap(key, true, -int256(1e20), "");
        swap(key, false, -int256(1e20), "");
        lpm.subscribe(tokenId, subscriber, "");
    }

    function _incParams(uint256 tokenId, uint256 a0, uint256 a1, uint256 minLiq)
        internal
        view
        returns (ISwapAndAdd.IncreaseParams memory)
    {
        return ISwapAndAdd.IncreaseParams({
            tokenId: tokenId,
            amount0In: a0,
            amount1In: a1,
            route: "",
            routeFunding: new ISwapAndAdd.TokenAmount[](0),
            minLiquidityAdded: minLiq,
            recipient: address(this),
            hookData: "",
            deadline: block.timestamp + 1
        });
    }

    // ─────────────────────────────── well-behaved subscriber: transparent ───────────────────────────────

    function test_increase_subscribedPosition_notifiesAndSucceeds() public {
        uint256 tokenId = _subscribedPosition(address(sub));
        uint128 before = lpm.getPositionLiquidity(tokenId);

        (uint128 added,,) = zap.increase(_incParams(tokenId, 1e18, 1e18, 1));

        assertGt(added, 0, "increase completed on a subscribed position");
        assertEq(lpm.getPositionLiquidity(tokenId), before + added, "position grew");
        // fee collect + INCREASE both notified (a trim, if any, adds a third)
        assertGe(sub.notifyModifyLiquidityCount(), 2, "collect and increase must both notify");
        assertEq(currency0.balanceOf(address(zap)), 0, "no token0 at rest");
        assertEq(currency1.balanceOf(address(zap)), 0, "no token1 at rest");
    }

    function test_compound_subscribedPosition_notifiesAndSucceeds() public {
        uint256 tokenId = _subscribedPosition(address(sub));
        uint128 before = lpm.getPositionLiquidity(tokenId);

        (uint128 added,,) = zap.compound(
            ISwapAndAdd.CompoundParams({
                tokenId: tokenId,
                route: "",
                minLiquidityAdded: 1,
                recipient: address(this),
                hookData: "",
                deadline: block.timestamp + 1
            })
        );

        assertGt(added, 0, "fees compounded on a subscribed position");
        assertGt(lpm.getPositionLiquidity(tokenId), before, "position grew");
        assertGe(sub.notifyModifyLiquidityCount(), 2, "collect and increase must both notify");
    }

    function test_rebalance_subscribedPosition_notifiesBurn_newPositionClean() public {
        uint256 tokenId = _subscribedPosition(address(sub));

        (uint256 newTokenId, uint128 liquidity,,) = zap.rebalance(
            ISwapAndAdd.RebalanceParams({
                tokenId: tokenId,
                additional0: 0,
                additional1: 0,
                newTickLower: -1200,
                newTickUpper: 1200,
                route: "",
                routeFunding: new ISwapAndAdd.TokenAmount[](0),
                minLiquidity: 1,
                recipient: address(this),
                hookData: "",
                deadline: block.timestamp + 1
            })
        );

        assertGt(liquidity, 0, "rebalance completed on a subscribed position");
        assertEq(sub.notifyBurnCount(), 1, "the burn must notify the subscriber");
        assertEq(address(lpm.subscriber(newTokenId)), address(0), "the fresh position carries no subscription over");
        assertEq(IERC721(address(lpm)).ownerOf(newTokenId), address(this), "owner receives the new NFT");
    }

    // ─────────────────────────────── reverting subscriber: self-DoS only, atomic ───────────────────────────────

    function test_increase_revertingSubscriber_revertsAtomically() public {
        MockRevertSubscriber rev = new MockRevertSubscriber(lpm);
        rev.setRevert(false); // let notifySubscribe pass; notifyModifyLiquidity always reverts
        uint256 tokenId = _subscribedPosition(address(rev));

        uint128 liqBefore = lpm.getPositionLiquidity(tokenId);
        uint256 c0Before = currency0.balanceOf(address(this));

        // the revert is bubbled (wrapped) by the Notifier at the very first notification — the fee collect
        vm.expectRevert();
        zap.increase(_incParams(tokenId, 1e18, 1e18, 1));

        assertEq(lpm.getPositionLiquidity(tokenId), liqBefore, "no partial liquidity change");
        assertEq(currency0.balanceOf(address(this)), c0Before, "no funds consumed");
    }

    function test_rebalance_burnRevertingSubscriber_revertsAtomically() public {
        MockBurnRevertingSubscriber rev = new MockBurnRevertingSubscriber();
        uint256 tokenId = _subscribedPosition(address(rev));

        uint128 liqBefore = lpm.getPositionLiquidity(tokenId);

        vm.expectRevert();
        zap.rebalance(
            ISwapAndAdd.RebalanceParams({
                tokenId: tokenId,
                additional0: 0,
                additional1: 0,
                newTickLower: -1200,
                newTickUpper: 1200,
                route: "",
                routeFunding: new ISwapAndAdd.TokenAmount[](0),
                minLiquidity: 1,
                recipient: address(this),
                hookData: "",
                deadline: block.timestamp + 1
            })
        );

        assertEq(lpm.getPositionLiquidity(tokenId), liqBefore, "position untouched after the failed burn");
        assertEq(IERC721(address(lpm)).ownerOf(tokenId), address(this), "NFT untouched");
    }

    // ─────────────────────────── price-manipulating subscriber: gated by the floor ───────────────────────────

    function _swappingSetup() internal returns (uint256 tokenId, MockSwappingSubscriber swapper) {
        swapper = new MockSwappingSubscriber(lpm, manager);
        // fund the swapper so it can settle its own mid-operation trade
        MockERC20(Currency.unwrap(currency0)).mint(address(swapper), 1e22);
        tokenId = _subscribedPosition(address(swapper));
        swapper.config(key, 1e21); // fires on the fee collect, before the zap sizes from the live price
    }

    function test_increase_swappingSubscriber_floorReverts() public {
        (uint256 tokenId,) = _swappingSetup();

        // an honest floor quoted against the pre-manipulation price: the subscriber's swap makes the
        // operation miss it, and the whole thing reverts atomically — exactly the hook/route doctrine
        vm.expectPartialRevert(ISwapAndAdd.InsufficientLiquidity.selector);
        zap.increase(_incParams(tokenId, 1e18, 1e18, type(uint128).max));
    }

    function test_increase_swappingSubscriber_floorAcceptsOutcome() public {
        (uint256 tokenId, MockSwappingSubscriber swapper) = _swappingSetup();
        (, int24 tickBefore,,) = manager.getSlot0(key.toId());
        uint128 before = lpm.getPositionLiquidity(tokenId);

        (uint128 added,,) = zap.increase(_incParams(tokenId, 1e18, 1e18, 1));

        (, int24 tickAfter,,) = manager.getSlot0(key.toId());
        assertTrue(swapper.swapped(), "the subscriber traded mid-operation");
        assertTrue(tickAfter != tickBefore, "the pool price actually moved");
        assertGt(added, 0, "operation completed at the manipulated price");
        assertEq(lpm.getPositionLiquidity(tokenId), before + added, "position grew in place");
        assertEq(currency0.balanceOf(address(zap)), 0, "no token0 at rest");
        assertEq(currency1.balanceOf(address(zap)), 0, "no token1 at rest");
    }
}
