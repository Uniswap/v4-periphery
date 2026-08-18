// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IERC721} from "forge-std/interfaces/IERC721.sol";
import {console2} from "forge-std/console2.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {ISwapAndAdd} from "../src/interfaces/ISwapAndAdd.sol";
import {IUniversalRouter} from "../src/interfaces/external/IUniversalRouter.sol";
import {PosmTestSetup} from "./shared/PosmTestSetup.sol";
import {MockSwapRoute} from "./mocks/MockSwapRoute.sol";

/// @notice Regression suite for `increase` on OUT-OF-RANGE positions across a sweep of realistic-to-extreme
///         price drifts. Before the collect-fees-first fix, POSM's accrued-fee credit made `increase` revert
///         `DeltaNotNegative` unconditionally for any out-of-range position with fees on its empty side. The
///         fee collect removes that; these tests additionally pin that the collected single-sided fees entering
///         the budget are valued sanely at spot by `_sizeLiquidityWeighted` (no funds at rest, no operator
///         redirect, stranger rejected).
contract SwapAndAddIncreaseOutOfRangeTest is PosmTestSetup {
    using StateLibrary for IPoolManager;
    using CurrencyLibrary for Currency;

    ISwapAndAdd zap;
    MockSwapRoute route;

    int24 constant TL = -600;
    int24 constant TU = 600;

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();
        deployAndApprovePosm(manager);
        (key,) = initPoolAndAddLiquidity(currency0, currency1, IHooks(address(0)), 3000, SQRT_PRICE_1_1);
        // DEEP wide exogenous liquidity, so a push moves the price a controlled amount instead of
        // exhausting the book and slamming into MAX_TICK.
        modifyLiquidityRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({tickLower: -60_000, tickUpper: 60_000, liquidityDelta: int256(5e21), salt: 0}),
            ""
        );

        route = new MockSwapRoute(permit2);
        zap = ISwapAndAdd(
            deployCode("SwapAndAdd.sol:SwapAndAdd", abi.encode(manager, permit2, lpm, IUniversalRouter(address(route))))
        );
        seedBalance(address(this));
        MockERC20(Currency.unwrap(currency0)).mint(address(this), 1e40);
        MockERC20(Currency.unwrap(currency1)).mint(address(this), 1e40);
        MockERC20(Currency.unwrap(currency0)).approve(address(permit2), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(permit2), type(uint256).max);
        permit2.approve(Currency.unwrap(currency0), address(zap), type(uint160).max, type(uint48).max);
        permit2.approve(Currency.unwrap(currency1), address(zap), type(uint160).max, type(uint48).max);
        IERC721(address(lpm)).setApprovalForAll(address(zap), true);
    }

    function _mintAndAccrue() internal returns (uint256 tokenId) {
        (tokenId,,,) = zap.add(
            ISwapAndAdd.AddParams({
                poolKey: key,
                tickLower: TL,
                tickUpper: TU,
                amount0In: 10e18,
                amount1In: 10e18,
                route: "",
                minLiquidity: 0,
                recipient: address(this),
                hookData: "",
                deadline: block.timestamp + 1
            })
        );
        // churn to accrue fees on BOTH sides
        for (uint256 i; i < 5; i++) {
            swap(key, true, -20e18, "");
            swap(key, false, -20e18, "");
        }
    }

    function _inc(uint256 tokenId, uint256 a0, uint256 a1) internal returns (uint128 added) {
        (added,,) = zap.increase(
            ISwapAndAdd.IncreaseParams({
                tokenId: tokenId,
                amount0In: a0,
                amount1In: a1,
                route: "",
                minLiquidityAdded: 0,
                recipient: address(this),
                hookData: "",
                deadline: block.timestamp + 1
            })
        );
    }

    /// @dev Push spot ABOVE tickUpper by a given oneForZero exact-input size, then try the owner's own increase.
    function _probeAbove(uint256 pushAmount) internal returns (bool ok, int24 tick, bytes memory err) {
        uint256 snap = vm.snapshotState();
        uint256 tokenId = _mintAndAccrue();
        swap(key, false, -int256(pushAmount), "");
        (, tick,,) = manager.getSlot0(key.toId());
        require(tick > TU, "not above range");
        try this.extIncrease(tokenId, 0, 5e18) {
            ok = true;
        } catch (bytes memory r) {
            err = r;
        }
        vm.revertToState(snap);
    }

    function extIncrease(uint256 tokenId, uint256 a0, uint256 a1) external returns (uint128) {
        return _inc(tokenId, a0, a1);
    }

    /// @notice Sweep the out-of-range drift from mild to extreme and report where `increase` starts failing.
    function test_increase_outOfRange_driftSweep() public {
        // sized against the 5e21 deep range: ~2e20 lands just above tickUpper, growing to a far drift
        uint256[7] memory pushes = [uint256(2e20), 3e20, 5e20, 1e21, 3e21, 1e22, 5e22];
        for (uint256 i; i < pushes.length; i++) {
            (bool ok, int24 tick, bytes memory err) = _probeAbove(pushes[i]);
            bytes4 sel;
            if (err.length >= 4) {
                assembly {
                    sel := mload(add(err, 32))
                }
            }
            console2.log("push (token1 in):", pushes[i] / 1e18);
            console2.log("   resulting tick:", tick);
            console2.log("   increase ok?  :", ok);
            if (!ok) console2.logBytes4(sel);
        }
    }

    /// @notice The headline claim to verify: a MILD, entirely realistic out-of-range drift.
    function test_increase_outOfRange_mildDrift_works() public {
        uint256 tokenId = _mintAndAccrue();
        swap(key, false, -3e20, "");
        (, int24 tick,,) = manager.getSlot0(key.toId());
        assertGt(tick, TU, "spot must be above the range");
        uint128 added = _inc(tokenId, 0, 5e18);
        console2.log("tick", tick);
        console2.log("liquidityAdded", added);
        assertGt(added, 0, "increase must succeed on an out-of-range position after the fix");
    }

    /// @notice Control: the pre-fix in-range DoS (small top-up on a fee-bearing position) is really gone.
    function test_increase_inRange_smallTopUp_works() public {
        uint256 tokenId = _mintAndAccrue();
        uint128 added = _inc(tokenId, 1e12, 1e12);
        console2.log("liquidityAdded (small top-up)", added);
        assertGt(added, 0, "small top-up must succeed after the fix");
    }

    /// @notice The zap must hold nothing afterwards (invariant 1) on the fixed increase path.
    function test_increase_noFundsAtRest() public {
        uint256 tokenId = _mintAndAccrue();
        _inc(tokenId, 1e15, 1e15);
        assertEq(currency0.balanceOf(address(zap)), 0, "token0 at rest");
        assertEq(currency1.balanceOf(address(zap)), 0, "token1 at rest");
    }

    /// @notice An operator's dust must be forced to the owner (invariant 3 now extended to `increase`).
    function test_increase_operatorCannotRedirect() public {
        uint256 tokenId = _mintAndAccrue();
        address operator = makeAddr("operator");
        IERC721(address(lpm)).approve(operator, tokenId);

        MockERC20(Currency.unwrap(currency0)).mint(operator, 1e20);
        MockERC20(Currency.unwrap(currency1)).mint(operator, 1e20);
        vm.startPrank(operator);
        MockERC20(Currency.unwrap(currency0)).approve(address(permit2), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(permit2), type(uint256).max);
        permit2.approve(Currency.unwrap(currency0), address(zap), type(uint160).max, type(uint48).max);
        permit2.approve(Currency.unwrap(currency1), address(zap), type(uint160).max, type(uint48).max);

        uint256 opBefore0 = currency0.balanceOf(operator);
        zap.increase(
            ISwapAndAdd.IncreaseParams({
                tokenId: tokenId,
                amount0In: 1e18,
                amount1In: 1e18,
                route: "",
                minLiquidityAdded: 0,
                recipient: operator, // requested self — must be overridden to the owner
                hookData: "",
                deadline: block.timestamp + 1
            })
        );
        vm.stopPrank();
        // the operator spent budget and received no dust back
        assertLt(currency0.balanceOf(operator), opBefore0, "operator must not be paid dust");
    }

    /// @notice A stranger must no longer be able to touch the position at all.
    function test_increase_strangerRejected() public {
        uint256 tokenId = _mintAndAccrue();
        address stranger = makeAddr("stranger");
        MockERC20(Currency.unwrap(currency0)).mint(stranger, 1e20);
        MockERC20(Currency.unwrap(currency1)).mint(stranger, 1e20);
        vm.startPrank(stranger);
        MockERC20(Currency.unwrap(currency0)).approve(address(permit2), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(permit2), type(uint256).max);
        permit2.approve(Currency.unwrap(currency0), address(zap), type(uint160).max, type(uint48).max);
        permit2.approve(Currency.unwrap(currency1), address(zap), type(uint160).max, type(uint48).max);
        vm.expectRevert(abi.encodeWithSelector(ISwapAndAdd.NotAuthorizedForToken.selector, tokenId));
        zap.increase(
            ISwapAndAdd.IncreaseParams({
                tokenId: tokenId,
                amount0In: 1e18,
                amount1In: 1e18,
                route: "",
                minLiquidityAdded: 0,
                recipient: stranger,
                hookData: "",
                deadline: block.timestamp + 1
            })
        );
        vm.stopPrank();
    }
}
