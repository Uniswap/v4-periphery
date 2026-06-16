// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {RoutingTestHelpers} from "../shared/RoutingTestHelpers.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {IWETH9} from "../../src/interfaces/external/IWETH9.sol";
import {IV4Router} from "../../src/interfaces/IV4Router.sol";
import {MarginRouter} from "../../src/MarginRouter.sol";
import {IMarginRouter} from "../../src/interfaces/IMarginRouter.sol";
import {MarginAccount} from "../../src/MarginAccount.sol";
import {Market} from "../../src/types/Market.sol";
import {MockLendingAdapter} from "../mocks/MockLendingAdapter.sol";
import {MockLendingProtocol} from "../mocks/MockLendingProtocol.sol";

/// @notice Regression coverage for the V4Router exact-output per-hop price guard. A v4 exact-output
///         swap partially fills when a pool lacks liquidity across the tick range; the router must
///         price the REALIZED output (not the requested amount) against the actual input, or the
///         `minHopPriceX36` bound silently overstates the execution price. Driven through the real
///         `MarginRouter.openPosition` path against a thin local v4 pool.
contract MarginRouterExactOutputShortFillTest is RoutingTestHelpers {
    uint256 internal constant PRECISION = 1e36;
    uint256 internal constant INITIAL_EQUITY = 1 ether;
    uint128 internal constant REQUESTED_COLLATERAL = 1 ether;
    uint128 internal constant MAX_DEBT_IN = 2 ether;

    MarginRouter internal marginRouter;
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

        address impl = address(new MarginAccount());
        marginRouter =
            new MarginRouter(manager, IAllowanceTransfer(address(0xdead)), IWETH9(address(0xbeef)), impl, address(this));
        marginRouter.setAdapterAllowed(adapter, true);

        MockERC20(Currency.unwrap(debt)).transfer(address(protocol), 1_000_000 ether);
    }

    /// @notice With no price bound the exact-output swap under-fills and the open succeeds with a
    ///         smaller position. This documents the residual partial-fill behavior the price-guard fix
    ///         intentionally does not change: `minHopPriceX36` bounds price, not delivered amount, and
    ///         `maxDebtIn` still binds the spend.
    function test_openPosition_partialFillSucceedsWithoutPriceBound() public {
        (, uint256 bought, uint256 spent) = _open(0);
        assertGt(bought, 0, "swap fills partially, not zero");
        assertLt(bought, REQUESTED_COLLATERAL, "thin pool under-fills the exact-output request");
        assertLe(spent, MAX_DEBT_IN, "input cap still binds the debt spent");
    }

    /// @notice With a `minHopPriceX36` above the realized execution price, the open now reverts. Before
    ///         the fix the guard divided the REQUESTED output by the actual input, overstating the
    ///         price, and let the under-filled trade through.
    function test_openPosition_minHopGuardRevertsOnShortFillPrice() public {
        // discover the realized price on this thin pool with no bound, then roll back
        uint256 snap = vm.snapshotState();
        (, uint256 bought, uint256 spent) = _open(0);
        uint256 realizedPriceX36 = bought * PRECISION / spent;
        vm.revertToState(snap);

        // a bound strictly above the realized price must now be enforced against the realized output;
        // the guard reverts reporting (bound, realized) -- previously it compared the requested output
        uint256 minPrice = realizedPriceX36 + 1e34;

        // pre-fund equity outside the expectRevert so the cheatcode applies to the openPosition call
        address account = marginRouter.accountOf(address(this), 0);
        MockERC20(Currency.unwrap(collateral)).transfer(account, INITIAL_EQUITY);

        vm.expectRevert(
            abi.encodeWithSelector(IV4Router.V4TooMuchRequestedPerHopSingle.selector, minPrice, realizedPriceX36)
        );
        marginRouter.openPosition(
            IMarginRouter.OpenParams({
                adapter: adapter,
                market: market,
                poolKey: thinOpenPoolKey,
                equity: 0,
                collateralToBuy: REQUESTED_COLLATERAL,
                maxDebtIn: MAX_DEBT_IN,
                minHopPriceX36: minPrice,
                subId: 0,
                deadline: block.timestamp + 1
            })
        );
    }

    /// @notice A thin pool that cannot buy back the full debt makes the close revert atomically (the
    ///         repay needs more debt token than the swap delivered). This is the fail-safe outcome:
    ///         no partial close, no corrupted state.
    function test_closePosition_revertsWhenThinPoolCannotBuyAllDebt() public {
        address account = marginRouter.createAccount(address(this), 7);

        MockERC20(Currency.unwrap(collateral)).transfer(account, 1 ether);
        MarginAccount(account).supplyCollateral(adapter, market, 1 ether);
        MarginAccount(account).borrow(adapter, market, 1 ether, address(this));

        vm.expectRevert();
        marginRouter.closePosition(
            IMarginRouter.CloseParams({
                adapter: adapter,
                market: market,
                poolKey: thinClosePoolKey,
                maxCollateralIn: 2 ether,
                minHopPriceX36: 0,
                subId: 7,
                deadline: block.timestamp + 1
            })
        );
    }

    function _open(uint256 minHopPriceX36)
        internal
        returns (address account, uint256 collateralBought, uint256 debtBorrowed)
    {
        account = marginRouter.accountOf(address(this), 0);
        MockERC20(Currency.unwrap(collateral)).transfer(account, INITIAL_EQUITY);

        account = marginRouter.openPosition(
            IMarginRouter.OpenParams({
                adapter: adapter,
                market: market,
                poolKey: thinOpenPoolKey,
                equity: 0,
                collateralToBuy: REQUESTED_COLLATERAL,
                maxDebtIn: MAX_DEBT_IN,
                minHopPriceX36: minHopPriceX36,
                subId: 0,
                deadline: block.timestamp + 1
            })
        );

        collateralBought = protocol.collateralOf(account) - INITIAL_EQUITY;
        debtBorrowed = protocol.debtOf(account);
    }

    function _createThinPool(uint24 fee, int24 lowerTick, int24 upperTick) internal returns (PoolKey memory key) {
        key = PoolKey({currency0: collateral, currency1: debt, fee: fee, tickSpacing: 60, hooks: IHooks(address(0))});

        manager.initialize(key, SQRT_PRICE_1_1);
        MockERC20(Currency.unwrap(collateral)).approve(address(positionManager), type(uint256).max);
        MockERC20(Currency.unwrap(debt)).approve(address(positionManager), type(uint256).max);
        positionManager.modifyLiquidity(key, ModifyLiquidityParams(lowerTick, upperTick, 200 ether, 0), "0x");
    }
}
