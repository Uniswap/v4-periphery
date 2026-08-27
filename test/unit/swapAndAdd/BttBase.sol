// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {FixedPoint96} from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {IERC721} from "forge-std/interfaces/IERC721.sol";
import {Vm} from "forge-std/Vm.sol";

import {PosmTestSetup} from "../../shared/PosmTestSetup.sol";
import {Actions} from "../../../src/libraries/Actions.sol";
import {ISwapAndAdd} from "../../../src/interfaces/ISwapAndAdd.sol";
import {IUniversalRouter} from "../../../src/interfaces/external/IUniversalRouter.sol";
import {MockSwapRoute} from "../../mocks/MockSwapRoute.sol";
import {ISwapAndAddHarness} from "./ISwapAndAddHarness.sol";

/// @notice Shared fixture for SwapAndAdd BTT unit tests.
///         Deploys `SwapAndAddHarness` via `deployCode` so tests stay via_ir=false.
contract BttBase is PosmTestSetup {
    using StateLibrary for IPoolManager;
    using CurrencyLibrary for Currency;

    ISwapAndAddHarness internal zap;
    MockSwapRoute internal route;

    int24 internal constant TICK_LOWER = -600;
    int24 internal constant TICK_UPPER = 600;
    bytes internal constant ROUTE_PAYLOAD = abi.encode(bytes(""), new bytes[](0));
    ISwapAndAdd.TokenAmount[] internal NO_FUNDING;

    function setUp() public virtual {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();
        deployAndApprovePosm(manager);

        (key,) = initPoolAndAddLiquidity(currency0, currency1, IHooks(address(0)), 3000, SQRT_PRICE_1_1);
        seedMoreLiquidity(key, 1_000e18, 1_000e18);

        route = new MockSwapRoute(permit2);
        zap = ISwapAndAddHarness(
            deployCode(
                "SwapAndAddHarness.sol:SwapAndAddHarness",
                abi.encode(manager, permit2, lpm, IUniversalRouter(address(route)))
            )
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
    }

    function _approveZap(Currency c) internal {
        MockERC20(Currency.unwrap(c)).approve(address(permit2), type(uint256).max);
        permit2.approve(Currency.unwrap(c), address(zap), type(uint160).max, type(uint48).max);
    }

    function _approveZapFor(address account, Currency c) internal {
        vm.startPrank(account);
        MockERC20(Currency.unwrap(c)).approve(address(permit2), type(uint256).max);
        permit2.approve(Currency.unwrap(c), address(zap), type(uint160).max, type(uint48).max);
        vm.stopPrank();
    }

    function _core(PoolKey memory poolKey, uint256 budget0, uint256 budget1)
        internal
        view
        returns (ISwapAndAddHarness.CoreParams memory cp)
    {
        cp = ISwapAndAddHarness.CoreParams({
            deployTokenId: 0,
            key: poolKey,
            tickLower: TICK_LOWER,
            tickUpper: TICK_UPPER,
            budget0: budget0,
            budget1: budget1,
            route: "",
            minLiquidity: 0,
            recipient: address(this),
            hookData: ""
        });
    }

    function _addParams(uint256 amount0In, uint256 amount1In) internal view returns (ISwapAndAdd.AddParams memory) {
        return ISwapAndAdd.AddParams({
            poolKey: key,
            tickLower: TICK_LOWER,
            tickUpper: TICK_UPPER,
            amount0In: amount0In,
            amount1In: amount1In,
            route: "",
            routeFunding: NO_FUNDING,
            minLiquidity: 0,
            recipient: address(this),
            hookData: "",
            deadline: block.timestamp + 1
        });
    }

    function _addParams(int24 tickLower, int24 tickUpper, uint256 amount0In, uint256 amount1In)
        internal
        view
        returns (ISwapAndAdd.AddParams memory)
    {
        ISwapAndAdd.AddParams memory p = _addParams(amount0In, amount1In);
        p.tickLower = tickLower;
        p.tickUpper = tickUpper;
        return p;
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
            routeFunding: NO_FUNDING,
            minLiquidityAdded: 0,
            recipient: address(this),
            hookData: "",
            deadline: block.timestamp + 1
        });
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
            routeFunding: NO_FUNDING,
            minLiquidity: 0,
            recipient: address(this),
            hookData: "",
            deadline: block.timestamp + 1
        });
    }

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

    function _emptyFunding() internal pure returns (ISwapAndAdd.TokenAmount[] memory funding) {
        funding = new ISwapAndAdd.TokenAmount[](0);
    }

    /// @dev The single log the zap emitted since `vm.recordLogs()`. Asserts there is exactly one.
    function _zapLog() internal returns (Vm.Log memory) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 found = type(uint256).max;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == address(zap)) {
                assertEq(found, type(uint256).max, "exactly one zap event per operation");
                found = i;
            }
        }
        assertTrue(found != type(uint256).max, "the operation must emit a zap event");
        return logs[found];
    }

    function _assertZapIdle() internal view {
        assertEq(currency0.balanceOf(address(zap)), 0, "zap token0");
        assertEq(currency1.balanceOf(address(zap)), 0, "zap token1");
        assertEq(address(zap).balance, 0, "zap eth");
    }

    function _sqrtBounds() internal pure returns (uint160 sqrtLower, uint160 sqrtUpper) {
        sqrtLower = TickMath.getSqrtPriceAtTick(TICK_LOWER);
        sqrtUpper = TickMath.getSqrtPriceAtTick(TICK_UPPER);
    }

    function _approvePosmForZap() internal {
        IERC721(address(lpm)).setApprovalForAll(address(zap), true);
    }

    function _emptyPosition(uint256 tokenId) internal {
        bytes memory actions = abi.encodePacked(uint8(Actions.DECREASE_LIQUIDITY), uint8(Actions.TAKE_PAIR));
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(tokenId, uint256(lpm.getPositionLiquidity(tokenId)), uint128(0), uint128(0), bytes(""));
        params[1] = abi.encode(key.currency0, key.currency1, address(this));
        lpm.modifyLiquidities(abi.encode(actions, params), block.timestamp + 1);
        assertEq(lpm.getPositionLiquidity(tokenId), 0, "position emptied");
    }

    function _generateFees() internal {
        for (uint256 i = 0; i < 5; i++) {
            swap(key, true, -50e18, "");
            swap(key, false, -50e18, "");
        }
    }

    function _generateFees(PoolKey memory poolKey) internal {
        for (uint256 i = 0; i < 5; i++) {
            swap(poolKey, true, -50e18, "");
            swap(poolKey, false, -50e18, "");
        }
    }

    function _configRoute(uint256 rateMultBps, uint256 inputAmount) internal {
        route.config(
            Currency.unwrap(currency1), Currency.unwrap(currency0), FixedPoint96.Q96, rateMultBps, inputAmount, false
        );
    }

    function _routeAdd(uint256 amount1In) internal view returns (ISwapAndAdd.AddParams memory p) {
        p = _addParams(0, amount1In);
        p.route = ROUTE_PAYLOAD;
    }

    function _nativeAdd(uint256 nativeIn) internal returns (uint256 tokenId) {
        ISwapAndAdd.AddParams memory p = _addParams(nativeIn, 0);
        p.poolKey = nativeKey;
        (tokenId,,,) = zap.add{value: nativeIn}(p);
    }

    function _fundZap(Currency c, uint256 amount) internal {
        if (c.isAddressZero()) {
            vm.deal(address(zap), address(zap).balance + amount);
        } else {
            MockERC20(Currency.unwrap(c)).mint(address(zap), amount);
        }
    }

    function _mintPositionViaAdd(uint256 amount0In, uint256 amount1In) internal returns (uint256 tokenId) {
        (tokenId,,,) = zap.add(_addParams(amount0In, amount1In));
        _approvePosmForZap();
    }
}
