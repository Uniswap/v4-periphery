// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {RoutingTestHelpers} from "../shared/RoutingTestHelpers.sol";
import {MarginRouteHelpers} from "../shared/MarginRouteHelpers.sol";
import {DeployPermit2} from "permit2/test/utils/DeployPermit2.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {IWETH9} from "../../src/interfaces/external/IWETH9.sol";
import {IV4Router} from "../../src/interfaces/IV4Router.sol";
import {IMarginRouter} from "../../src/interfaces/IMarginRouter.sol";
import {MarginAccount} from "../../src/MarginAccount.sol";
import {Market} from "../../src/types/Market.sol";
import {Ltv} from "../../src/types/Ltv.sol";
import {MockLendingAdapter} from "../mocks/MockLendingAdapter.sol";
import {MockLendingProtocol} from "../mocks/MockLendingProtocol.sol";

/// @notice Regression coverage for two related fixes around v4 exact-output partial fills, exercised
///         through the real `MarginRouter.increasePosition` path against a thin local v4 pool:
///           - Fix A: the V4Router per-hop price guard prices the REALIZED output (not the requested
///             amount), so a bound the true price violates reverts with `V4TooMuchRequestedPerHopSingle`.
///           - Option C: `_open` takes EXACTLY `collateralToBuy`, so an exact-output swap that
///             under-fills leaves an unsettled collateral debt and the open reverts (all-or-nothing)
///             rather than silently opening a smaller position.
contract MarginRouterExactOutputShortFillTest is RoutingTestHelpers, MarginRouteHelpers, DeployPermit2 {
    uint256 internal constant INITIAL_EQUITY = 1 ether;
    uint128 internal constant REQUESTED_COLLATERAL = 1 ether;
    uint128 internal constant MAX_DEBT_IN = 2 ether;

    IMarginRouter internal marginRouter;
    address internal ur;
    MockLendingAdapter internal adapter;
    MockLendingProtocol internal protocol;

    Market internal market;
    PoolKey internal thinOpenPoolKey;
    PoolKey internal thinClosePoolKey;

    Currency internal collateral;
    Currency internal debt;

    function setUp() public {
        setupRouterCurrenciesAndPoolsWithLiquidity();

        collateral = currency0;
        debt = currency1;
        market = Market({collateral: collateral, debt: debt});

        // liquidity in a single tick-spacing band -> a 1 ETH exact-output request cannot fully fill
        thinOpenPoolKey = _createThinPool(3001, 0, 60);
        thinClosePoolKey = _createThinPool(3002, -60, 0);

        protocol = new MockLendingProtocol(IERC20(Currency.unwrap(collateral)), IERC20(Currency.unwrap(debt)));
        adapter = new MockLendingAdapter(address(protocol));
        adapter.setSupported(market, true);

        address permit2 = deployPermit2();
        address impl = address(new MarginAccount());
        // route position swaps through a Universal Router bound to the local PoolManager
        ur = deployUniversalRouter(address(manager), permit2, address(0xbeef));
        marginRouter = IMarginRouter(
            deployMarginRouter(manager, IAllowanceTransfer(permit2), IWETH9(address(0xbeef)), impl, address(this))
        );
        marginRouter.setAdapterAllowed(adapter, true);

        MockERC20(Currency.unwrap(debt)).transfer(address(protocol), 1_000_000 ether);
    }

    /// @notice With no price bound the UR-routed exact-output swap under-fills the thin pool, and the
    ///         `ASSERT_ACCOUNT_BALANCE` guard reverts the margin-level `IncompleteFill` error rather than
    ///         silently opening a smaller position. The open is all-or-nothing. No equity is pre-funded,
    ///         so the account holds only the swap output; `maxDebtIn` (2 ether) sits far above the ~0.6
    ///         ether the swap actually spends, so the swap partial-fills at the pool's price limit (it
    ///         does not trip the input cap) and leaves the account below `collateralToBuy`.
    function test_increasePosition_revertsOnPartialFill() public {
        (bytes memory cmds, bytes[] memory ins) = _openRoute(0);
        vm.expectPartialRevert(IMarginRouter.IncompleteFill.selector);
        _open(cmds, ins);
    }

    /// @notice Fix A: a per-hop bound the realized price cannot meet trips the price guard during the
    ///         swap (a clear error), before the all-or-nothing take is reached. Before the fix the guard
    ///         compared the requested output and let an under-filled trade through.
    function test_increasePosition_priceGuardRevertsOnRealizedPrice() public {
        _fundEquity();
        // 2.0 collateral-per-debt is unreachable buying at ~1:1, so the realized price is far below it
        (bytes memory cmds, bytes[] memory ins) = _openRoute(2e36);
        vm.expectPartialRevert(IV4Router.V4TooMuchRequestedPerHopSingle.selector);
        _open(cmds, ins);
    }

    /// @notice A thin pool that cannot buy back the full debt makes the close revert atomically. The
    ///         decrease path's ASSERT_FILL catches the exact-output under-fill and reverts with the
    ///         explicit `IncompleteFill` error, before the take/repay would fail opaquely. Fail-safe:
    ///         no partial close.
    function test_close_revertsWhenThinPoolCannotBuyAllDebt() public {
        address account = marginRouter.createAccount(address(this), 7);

        MockERC20(Currency.unwrap(collateral)).transfer(account, 1 ether);
        MarginAccount(payable(account)).supplyCollateral(adapter, market, 1 ether);
        MarginAccount(payable(account)).borrow(adapter, market, 1 ether, address(this));

        (, uint256 curDebt) = adapter.positionOf(account, market);
        (bytes memory cmds, bytes[] memory ins) =
            buildV4ExactOutRoute(thinClosePoolKey, collateral, debt, uint128(curDebt), 2 ether, account);
        vm.expectPartialRevert(IMarginRouter.IncompleteFill.selector);
        marginRouter.decreasePosition(
            IMarginRouter.DecreaseParams({
                debtToRepay: type(uint256).max,
                maxLtvAfter: Ltv.wrap(0),
                adapter: adapter,
                market: market,
                maxCollateralIn: 2 ether,
                universalRouter: ur,
                routeCommands: cmds,
                routeInputs: ins,
                subId: 7,
                deadline: block.timestamp + 1
            })
        );
    }

    function _fundEquity() internal {
        MockERC20(Currency.unwrap(collateral)).transfer(marginRouter.accountOf(address(this), 0), INITIAL_EQUITY);
    }

    /// @dev Builds the increase route over the thin open pool with an optional per-hop price bound.
    ///      Kept separate so the caller computes it BEFORE an `expectRevert` (the `accountOf` read would
    ///      otherwise be the call the cheatcode expects to revert).
    function _openRoute(uint256 minHopPriceX36) internal view returns (bytes memory cmds, bytes[] memory ins) {
        address account = marginRouter.accountOf(address(this), 0);
        (cmds, ins) = buildV4ExactOutRoute(
            thinOpenPoolKey, debt, collateral, REQUESTED_COLLATERAL, MAX_DEBT_IN, account, minHopPriceX36
        );
    }

    function _open(bytes memory cmds, bytes[] memory ins) internal {
        marginRouter.increasePosition(
            IMarginRouter.IncreaseParams({
                adapter: adapter,
                market: market,
                equity: 0,
                collateralToBuy: REQUESTED_COLLATERAL,
                maxDebtIn: MAX_DEBT_IN,
                universalRouter: ur,
                routeCommands: cmds,
                routeInputs: ins,
                maxLtvAfter: Ltv.wrap(0),
                subId: 0,
                deadline: block.timestamp + 1
            })
        );
    }

    function _createThinPool(uint24 fee, int24 lowerTick, int24 upperTick) internal returns (PoolKey memory key) {
        key = PoolKey({currency0: collateral, currency1: debt, fee: fee, tickSpacing: 60, hooks: IHooks(address(0))});

        manager.initialize(key, SQRT_PRICE_1_1);
        MockERC20(Currency.unwrap(collateral)).approve(address(positionManager), type(uint256).max);
        MockERC20(Currency.unwrap(debt)).approve(address(positionManager), type(uint256).max);
        positionManager.modifyLiquidity(key, ModifyLiquidityParams(lowerTick, upperTick, 200 ether, 0), "0x");
    }
}
