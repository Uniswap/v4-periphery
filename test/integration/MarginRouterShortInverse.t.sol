// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

import {IWETH9} from "../../src/interfaces/external/IWETH9.sol";
import {MarginRouter} from "../../src/MarginRouter.sol";
import {IMarginRouter} from "../../src/interfaces/IMarginRouter.sol";
import {MarginAccount} from "../../src/MarginAccount.sol";
import {AaveLendingAdapter} from "../../src/AaveLendingAdapter.sol";
import {Market} from "../../src/types/Market.sol";
import {Ltv, toLtv} from "../../src/types/Ltv.sol";
import {MockAavePool, MockAaveAddressesProvider, MockAaveDataProvider} from "../mocks/MockAavePool.sol";

/// @notice Local integration of a SHORT ETH position driven through the real MarginRouter,
///         MarginAccount, and AaveLendingAdapter against a MockAavePool and a real local v4
///         PoolManager seeded with a USDC/WETH pool. The market pairs USDC (6 decimals) as collateral
///         and WETH (18 decimals) as debt, so the caller is long USDC and short WETH. This is the
///         reversed-decimal layout of the long suite: equity and collateralToBuy are 6-decimal USDC
///         while maxDebtIn is 18-decimal WETH.
///
///         The flow proves the generalized borrow-to-account-then-forward path end to end: the
///         account borrows WETH from the mock pool (delivered to the account), forwards exactly that
///         amount to the router, and the router settles it into the opening swap. The key assertion
///         after open is that neither the account nor the router retains any loose USDC or WETH,
///         which is the settle proof for the borrow-forward change under reversed decimals.
contract MarginRouterShortInverseTest is Test {
    // USD base for the mock pool's getUserAccountData (Aave uses 8-decimal USD base; 1e8 == $1).
    uint256 internal constant USD = 1e8;
    // 1 WETH = 2000 USDC. Collateral (USDC) is $1; debt (WETH) is $2000.
    uint256 internal constant USDC_PRICE_BASE = 1 * USD;
    uint256 internal constant WETH_PRICE_BASE = 2000 * USD;
    // USDC liquidation threshold in basis points (78% == 7800 bps), as on a real reserve.
    uint256 internal constant USDC_LIQ_THRESHOLD_BPS = 7800;
    uint256 internal constant WETH_LIQ_THRESHOLD_BPS = 8000;

    // full range for tickSpacing 60 (matches the shared routing helpers)
    int24 internal constant MIN_TICK = -887_220;
    int24 internal constant MAX_TICK = 887_220;
    uint24 internal constant POOL_FEE = 3000;
    int24 internal constant TICK_SPACING = 60;

    // equal-value bundle defining the pool price: 2000 USDC raw == 1 WETH raw.
    uint256 internal constant USDC_BUNDLE = 2000e6;
    uint256 internal constant WETH_BUNDLE = 1e18;

    MockERC20 internal usdc; // collateral, 6 decimals
    MockERC20 internal weth; // debt, 18 decimals

    PoolManager internal manager;
    PoolModifyLiquidityTest internal lpRouter;
    MockAavePool internal aavePool;
    AaveLendingAdapter internal adapter;
    MarginRouter internal router;

    Market internal market;
    PoolKey internal poolKey;

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        weth = new MockERC20("Wrapped Ether", "WETH", 18);

        manager = new PoolManager(address(this));
        lpRouter = new PoolModifyLiquidityTest(IPoolManager(address(manager)));
        _initAndSeedPool();

        _deployAaveStack();

        MockAaveAddressesProvider provider = new MockAaveAddressesProvider(address(aavePool), address(_dataProvider));
        adapter = new AaveLendingAdapter(provider, address(this));
        // collateral USDC, debt WETH: long USDC, short WETH
        market = Market({collateral: Currency.wrap(address(usdc)), debt: Currency.wrap(address(weth))});
        adapter.setMarket(market.collateral, market.debt, true);

        address impl = address(new MarginAccount());
        router = new MarginRouter(
            IPoolManager(address(manager)), IAllowanceTransfer(address(0xdead)), IWETH9(address(0xbeef)), impl, address(this)
        );
        router.setAdapterAllowed(adapter, true);
    }

    // -------------------------------------------------------------------------
    // Tests
    // -------------------------------------------------------------------------

    /// @notice Open a short: 2000 USDC equity buys 2000 USDC of collateral funded by borrowed WETH.
    ///         Collateral lands at ~4000 USDC; debt is positive and within maxDebtIn. The settle
    ///         proof: neither the account nor the router holds any loose USDC or WETH afterward.
    function test_openShort_buildsPosition() public {
        address account = _openShort(2000e6, 2000e6, 1.1e18);
        vm.snapshotGasLastCall("MarginRouterShortInverse_openShort");

        (uint256 collateral, uint256 debt) = adapter.positionOf(account, market);
        assertApproxEqAbs(collateral, 4000e6, 1e6, "open: collateral = equity + bought");
        assertGt(debt, 0, "open: WETH debt drawn against the mock");
        assertLe(debt, 1.1e18, "open: debt within maxDebtIn");

        // the borrow-forward fully settled the WETH to the router and the swap consumed it
        assertEq(usdc.balanceOf(account), 0, "account holds no loose USDC");
        assertEq(weth.balanceOf(account), 0, "account holds no loose WETH");
        assertEq(usdc.balanceOf(address(router)), 0, "router holds no loose USDC");
        assertEq(weth.balanceOf(address(router)), 0, "router holds no loose WETH");
    }

    /// @notice Close a short: collateral USDC is sold to buy back the full WETH debt, which is then
    ///         repaid. Debt and collateral both go to zero on the mock and the residual USDC is
    ///         returned to the caller, with no router dust.
    function test_closeShort_repaysAndReturnsResidual() public {
        address account = _openShort(2000e6, 2000e6, 1.1e18);

        uint256 callerUsdcBefore = usdc.balanceOf(address(this));

        router.closePosition(
            IMarginRouter.CloseParams({
                adapter: adapter,
                market: market,
                poolKey: poolKey,
                maxCollateralIn: 6000e6,
                minHopPriceX36: 0,
                subId: 0,
                deadline: block.timestamp + 1 hours
            })
        );
        vm.snapshotGasLastCall("MarginRouterShortInverse_closeShort");

        (uint256 collateral, uint256 debt) = adapter.positionOf(account, market);
        assertEq(debt, 0, "close: WETH debt fully repaid");
        assertEq(collateral, 0, "close: all USDC collateral withdrawn");
        assertGt(usdc.balanceOf(address(this)) - callerUsdcBefore, 0, "close: residual USDC returned to caller");
        assertEq(usdc.balanceOf(address(router)), 0, "router holds no loose USDC");
        assertEq(weth.balanceOf(address(router)), 0, "router holds no loose WETH");
    }

    /// @notice Decrease a short: repay 0.3 WETH of debt funded by selling USDC collateral. Debt and
    ///         collateral both shrink but stay positive, and the resulting LTV passes the bound. This
    ///         exercises currentLtvWad and the resulting-LTV health assert through the mock.
    function test_decreaseShort_delevers() public {
        address account = _openShort(2000e6, 2000e6, 1.1e18);
        (uint256 collBefore, uint256 debtBefore) = adapter.positionOf(account, market);

        router.decreasePosition(
            IMarginRouter.DecreaseParams({
                adapter: adapter,
                market: market,
                poolKey: poolKey,
                debtToRepay: 0.3e18,
                maxCollateralIn: 1000e6,
                minHopPriceX36: 0,
                maxLtvAfter: toLtv(0.7e18),
                subId: 0,
                deadline: block.timestamp + 1 hours
            })
        );
        vm.snapshotGasLastCall("MarginRouterShortInverse_decreaseShort");

        (uint256 collAfter, uint256 debtAfter) = adapter.positionOf(account, market);
        assertLt(debtAfter, debtBefore, "decrease: WETH debt reduced");
        assertGt(debtAfter, 0, "decrease: position still open");
        assertLt(collAfter, collBefore, "decrease: USDC collateral sold to fund repay");
        assertGt(collAfter, 0, "decrease: collateral remains");
        assertEq(usdc.balanceOf(address(router)), 0, "router holds no loose USDC");
        assertEq(weth.balanceOf(address(router)), 0, "router holds no loose WETH");
    }

    /// @notice A stray USDC balance donated to the router is not swept to the caller on close: the
    ///         caller receives only their own realized residual and the donation stays in the router.
    function test_closeShort_doesNotSweepDonatedBalance() public {
        address account = _openShort(2000e6, 2000e6, 1.1e18);

        uint256 donation = 100e6;
        usdc.mint(address(router), donation);

        uint256 callerBefore = usdc.balanceOf(address(this));

        router.closePosition(
            IMarginRouter.CloseParams({
                adapter: adapter,
                market: market,
                poolKey: poolKey,
                maxCollateralIn: 6000e6,
                minHopPriceX36: 0,
                subId: 0,
                deadline: block.timestamp + 1 hours
            })
        );

        uint256 callerGain = usdc.balanceOf(address(this)) - callerBefore;
        assertGt(callerGain, 0, "caller receives their own residual");
        assertEq(usdc.balanceOf(address(router)), donation, "donated balance left in the router, not swept");
        assertEq(weth.balanceOf(address(router)), 0, "router holds no loose WETH");

        (uint256 collateral, uint256 debt) = adapter.positionOf(account, market);
        assertEq(debt, 0, "close: WETH debt fully repaid");
        assertEq(collateral, 0, "close: all USDC collateral withdrawn");
    }

    // -------------------------------------------------------------------------
    // Flow helpers (split to keep locals-per-frame low: tests compile without via_ir)
    // -------------------------------------------------------------------------

    /// @notice Funds the predicted account with `equity` USDC (skipping Permit2 by passing equity=0)
    ///         and opens a short buying `collateralToBuy` USDC of collateral, capped at `maxDebtIn`
    ///         WETH of borrow.
    function _openShort(uint256 equity, uint128 collateralToBuy, uint128 maxDebtIn) internal returns (address account) {
        account = router.accountOf(address(this), 0);
        // provide equity directly to the account; equity=0 in params avoids the Permit2 pull
        usdc.mint(account, equity);
        router.openPosition(
            IMarginRouter.OpenParams({
                adapter: adapter,
                market: market,
                poolKey: poolKey,
                equity: 0,
                collateralToBuy: collateralToBuy,
                maxDebtIn: maxDebtIn,
                minHopPriceX36: 0,
                subId: 0,
                deadline: block.timestamp + 1 hours
            })
        );
    }

    /// @notice Initializes the USDC/WETH pool at 1 WETH = 2000 USDC and seeds deep full-range
    ///         liquidity. Price is set from an equal-value bundle {2000e6 USDC, 1e18 WETH}: amt0/amt1
    ///         are assigned by sort order and sqrtPriceX96 = sqrt(amt1 * 2^192 / amt0).
    function _initAndSeedPool() internal {
        (Currency currency0, Currency currency1) = _sortedCurrencies();
        poolKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: POOL_FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(0))
        });

        manager.initialize(poolKey, _sqrtPriceX96());

        // deal generously and seed a large full-range position; depth far exceeds the few-thousand
        // USDC swaps the lifecycle performs
        usdc.mint(address(this), 1_000_000_000e6);
        weth.mint(address(this), 1_000_000 ether);
        usdc.approve(address(lpRouter), type(uint256).max);
        weth.approve(address(lpRouter), type(uint256).max);
        lpRouter.modifyLiquidity(
            poolKey,
            ModifyLiquidityParams({tickLower: MIN_TICK, tickUpper: MAX_TICK, liquidityDelta: 1e18, salt: 0}),
            ""
        );
    }

    /// @notice Sorts the USDC/WETH addresses into (currency0, currency1) canonical pool ordering.
    function _sortedCurrencies() internal view returns (Currency currency0, Currency currency1) {
        (currency0, currency1) = address(usdc) < address(weth)
            ? (Currency.wrap(address(usdc)), Currency.wrap(address(weth)))
            : (Currency.wrap(address(weth)), Currency.wrap(address(usdc)));
    }

    /// @notice The sqrtPriceX96 for 1 WETH = 2000 USDC, derived from the equal-value bundle. amt0/amt1
    ///         are the bundle's raw amounts assigned by sort order; sqrtPriceX96 = sqrt(amt1 * 2^192
    ///         / amt0), the v4 token1/token0 price.
    function _sqrtPriceX96() internal view returns (uint160 sqrtPriceX96) {
        (uint256 amt0, uint256 amt1) =
            address(usdc) < address(weth) ? (USDC_BUNDLE, WETH_BUNDLE) : (WETH_BUNDLE, USDC_BUNDLE);
        uint256 priceX192 = FullMath.mulDiv(amt1, uint256(1) << 192, amt0);
        sqrtPriceX96 = uint160(FixedPointMathLib.sqrt(priceX192));
        require(sqrtPriceX96 > TickMath.MIN_SQRT_PRICE && sqrtPriceX96 < TickMath.MAX_SQRT_PRICE, "price bounds");
    }

    MockAaveDataProvider internal _dataProvider;

    /// @notice Deploys the mock Aave stack, registers the USDC collateral and WETH debt reserves, and
    ///         funds the pool with WETH so borrow can deliver the debt asset to the account.
    function _deployAaveStack() internal {
        aavePool = new MockAavePool();
        _dataProvider = new MockAaveDataProvider(aavePool);

        MockERC20 aUsdc = new MockERC20("Aave USDC", "aUSDC", 6);
        MockERC20 vUsdc = new MockERC20("Variable Debt USDC", "vUSDC", 6);
        MockERC20 aWeth = new MockERC20("Aave WETH", "aWETH", 18);
        MockERC20 vWeth = new MockERC20("Variable Debt WETH", "vWETH", 18);

        aavePool.registerReserve(address(usdc), aUsdc, vUsdc, USDC_PRICE_BASE, USDC_LIQ_THRESHOLD_BPS);
        aavePool.registerReserve(address(weth), aWeth, vWeth, WETH_PRICE_BASE, WETH_LIQ_THRESHOLD_BPS);

        // fund the pool with WETH (the debt asset) so it can lend it out on borrow
        weth.mint(address(aavePool), 100_000 ether);
    }
}
