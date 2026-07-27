// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console2} from "forge-std/Test.sol";

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
import {IComet} from "../../src/interfaces/external/compound-v3/IComet.sol";
import {MarginRouter} from "../../src/MarginRouter.sol";
import {IMarginRouter} from "../../src/interfaces/IMarginRouter.sol";
import {MarginAccount} from "../../src/MarginAccount.sol";
import {CompoundV3LendingAdapter} from "../../src/CompoundV3LendingAdapter.sol";
import {Market} from "../../src/types/Market.sol";
import {Ltv, toLtv} from "../../src/types/Ltv.sol";

/// @notice Full-stack fork test of a leveraged long UNI position (collateral UNI, debt USDC) routed
///         through the CompoundV3LendingAdapter against the live mainnet USDC Comet. Exercises the
///         whole stack over open -> increase -> partial-decrease -> full-close, verifying the
///         adapter's encode/read mapping onto Comet's supply/withdraw model and that a full close
///         cleanly zeroes the borrow and withdraws all collateral.
contract CompoundV3LendingAdapterForkTest is Test {
    IComet internal constant COMET = IComet(0xc3d688B66703497DAA19211EEdff47f25384cdc3); // cUSDCv3
    address internal constant UNI = 0x1f9840a85d5aF5bf1D1762F925BDADdC4201F984; // 18 decimals, currency0
    address internal constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48; // 6 decimals, currency1 (base)
    address internal constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address internal constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    uint256 internal constant FORK_BLOCK = 25_598_384;

    uint256 internal constant UNI_LIQUIDATE_CF = 0.74e18; // verified on-chain
    int24 internal constant MIN_TICK = -887_220;
    int24 internal constant MAX_TICK = 887_220;

    PoolManager internal manager;
    PoolModifyLiquidityTest internal lpRouter;
    CompoundV3LendingAdapter internal adapter;
    MarginRouter internal router;
    Market internal market;
    PoolKey internal poolKey;

    receive() external payable {}

    function setUp() public {
        string memory rpc = vm.envOr("MAINNET_RPC_URL", string(""));
        vm.skip(bytes(rpc).length == 0);
        if (bytes(rpc).length == 0) return;
        vm.createSelectFork(rpc, FORK_BLOCK);

        market = Market({collateral: Currency.wrap(UNI), debt: Currency.wrap(USDC)});
        assertEq(COMET.baseToken(), USDC, "comet base is USDC");

        manager = new PoolManager(address(this));
        lpRouter = new PoolModifyLiquidityTest(IPoolManager(address(manager)));
        _initAndSeedPool();

        adapter = new CompoundV3LendingAdapter(COMET, address(this));
        address impl = address(new MarginAccount());
        router = new MarginRouter(
            IPoolManager(address(manager)), IAllowanceTransfer(PERMIT2), IWETH9(WETH), impl, address(this)
        );
        router.setAdapterAllowed(adapter, true);
        adapter.setMarket(Currency.wrap(UNI), Currency.wrap(USDC), true);
    }

    function test_fork_compound_longUni_lifecycle() public {
        address account = router.accountOf(address(this), 0);

        // ---- open: 1000 UNI equity, buy 1000 UNI more (~2x) with borrowed USDC ----
        deal(UNI, account, 1_000e18); // pre-fund equity to the account (equity = 0 avoids Permit2)
        router.increasePosition(
            IMarginRouter.IncreaseParams({
                adapter: adapter,
                market: market,
                poolKey: poolKey,
                equity: 0,
                collateralToBuy: 1_000e18,
                maxDebtIn: 20_000e6,
                minHopPriceX36: 0,
                maxLtvAfter: Ltv.wrap(0),
                subId: 0,
                deadline: block.timestamp + 1 hours
            })
        );

        (uint256 coll, uint256 debt) = adapter.positionOf(account, market);
        assertApproxEqAbs(coll, 2_000e18, 1, "open: collateral = equity + bought");
        assertGt(debt, 0, "open: USDC borrowed against UNI on Comet");
        assertEq(COMET.borrowBalanceOf(account), debt, "positionOf debt matches Comet borrowBalanceOf");
        _assertHealthy(account);
        _assertNoDust(account);
        assertEq(Ltv.unwrap(adapter.maxLtvWad(market)), UNI_LIQUIDATE_CF, "maxLtv = UNI liquidate CF");

        // ---- increase: buy +500 UNI of leverage, no new equity ----
        router.increasePosition(
            IMarginRouter.IncreaseParams({
                adapter: adapter,
                market: market,
                poolKey: poolKey,
                equity: 0,
                collateralToBuy: 500e18,
                maxDebtIn: 20_000e6,
                minHopPriceX36: 0,
                maxLtvAfter: Ltv.wrap(0),
                subId: 0,
                deadline: block.timestamp + 1 hours
            })
        );
        (uint256 coll2, uint256 debt2) = adapter.positionOf(account, market);
        assertApproxEqAbs(coll2, 2_500e18, 1, "increase: collateral grew by bought");
        assertGt(debt2, debt, "increase: debt grew");
        _assertHealthy(account);

        // ---- accrue a day of Comet interest, then partial decrease ----
        vm.warp(block.timestamp + 1 days);
        router.decreasePosition(
            IMarginRouter.DecreaseParams({
                adapter: adapter,
                market: market,
                poolKey: poolKey,
                debtToRepay: 1_000e6,
                maxCollateralIn: 2_000e18,
                minHopPriceX36: 0,
                maxLtvAfter: toLtv(0.7e18),
                subId: 0,
                deadline: block.timestamp + 1 hours
            })
        );
        (uint256 coll3, uint256 debt3) = adapter.positionOf(account, market);
        assertLt(debt3, debt2, "decrease: debt reduced");
        assertGt(debt3, 0, "decrease: position still open");
        assertLt(coll3, coll2, "decrease: collateral sold to fund repay");
        _assertHealthy(account);

        // ---- full close: repay all, withdraw all UNI, residual returned ----
        uint256 uniBefore = IERC20(UNI).balanceOf(address(this));
        router.decreasePosition(
            IMarginRouter.DecreaseParams({
                debtToRepay: type(uint256).max,
                maxLtvAfter: Ltv.wrap(0),
                adapter: adapter,
                market: market,
                poolKey: poolKey,
                maxCollateralIn: 3_000e18,
                minHopPriceX36: 0,
                subId: 0,
                deadline: block.timestamp + 1 hours
            })
        );

        (uint256 collEnd, uint256 debtEnd) = adapter.positionOf(account, market);
        assertEq(debtEnd, 0, "close: borrow fully repaid on Comet (no dust)");
        assertEq(collEnd, 0, "close: all UNI collateral withdrawn");
        uint256 residual = IERC20(UNI).balanceOf(address(this)) - uniBefore;
        assertGt(residual, 0, "close: residual UNI (realized PnL) returned to caller");
        console2.log("residual UNI returned:", residual);
        _assertNoDust(account);
    }

    /// @notice A full close after a long idle period (no Comet interaction since the open) still zeroes
    ///         the borrow and withdraws all collateral with no dust. Comet's `borrowBalanceOf` is
    ///         re-accrued to `block.timestamp` in the view, so the close swap and the repay are sized
    ///         off the true current debt even though the close is the first interaction since the open;
    ///         the repay caps at that borrow, so nothing is left un-repaid or stranded. Unlike the
    ///         lifecycle test above, there is deliberately no same-block interaction preceding the close.
    function test_fork_compound_fullClose_afterIdle_noDust() public {
        address account = router.accountOf(address(this), 0);

        deal(UNI, account, 1_000e18);
        router.increasePosition(
            IMarginRouter.IncreaseParams({
                adapter: adapter,
                market: market,
                poolKey: poolKey,
                equity: 0,
                collateralToBuy: 1_000e18,
                maxDebtIn: 20_000e6,
                minHopPriceX36: 0,
                maxLtvAfter: Ltv.wrap(0),
                subId: 0,
                deadline: block.timestamp + 1 hours
            })
        );
        (, uint256 debtAtOpen) = adapter.positionOf(account, market);
        assertGt(debtAtOpen, 0, "position open");

        // idle: no Comet interaction since the open; advance both timestamp and block number
        vm.warp(block.timestamp + 1 days);
        vm.roll(block.number + 7_200); // ~1 day at 12s/block

        // full close is the first Comet interaction since the open (no same-block interaction to
        // freshen a stored balance); it clears because borrowBalanceOf reflects the current block
        uint256 uniBefore = IERC20(UNI).balanceOf(address(this));
        router.decreasePosition(
            IMarginRouter.DecreaseParams({
                debtToRepay: type(uint256).max,
                maxLtvAfter: Ltv.wrap(0),
                adapter: adapter,
                market: market,
                poolKey: poolKey,
                maxCollateralIn: 3_000e18,
                minHopPriceX36: 0,
                subId: 0,
                deadline: block.timestamp + 1 hours
            })
        );

        (uint256 collEnd, uint256 debtEnd) = adapter.positionOf(account, market);
        assertEq(debtEnd, 0, "close: borrow fully repaid, no dust");
        assertEq(collEnd, 0, "close: all collateral withdrawn");
        assertGt(IERC20(UNI).balanceOf(address(this)), uniBefore, "close: residual returned to caller");
        _assertNoDust(account);
    }

    // ---- helpers ----

    /// @dev Seeds a local UNI/USDC v4 pool at the Comet oracle price so the swap leg and the Comet
    ///      valuation agree. UNI (0x1f..) sorts below USDC (0xA0..), so currency0 = UNI.
    function _initAndSeedPool() internal {
        require(UNI < USDC, "currency ordering");
        poolKey = PoolKey({
            currency0: Currency.wrap(UNI),
            currency1: Currency.wrap(USDC),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });

        // v4 price = token1/token0 = USDC_raw per UNI_raw. UNI priced in USDC = uniUsd / usdcUsd
        // (both 1e8), i.e. USDC per UNI; convert to raw ratio by 1e6/1e18 = /1e12.
        uint256 uniUsd = COMET.getPrice(COMET.getAssetInfoByAddress(UNI).priceFeed);
        uint256 usdcUsd = COMET.getPrice(COMET.baseTokenPriceFeed());
        // priceX192 = (uniUsd / (usdcUsd * 1e12)) << 192
        uint256 priceX192 = FullMath.mulDiv(uniUsd, uint256(1) << 192, usdcUsd * 1e12);
        uint160 sqrtPriceX96 = uint160(FixedPointMathLib.sqrt(priceX192));
        require(sqrtPriceX96 > TickMath.MIN_SQRT_PRICE && sqrtPriceX96 < TickMath.MAX_SQRT_PRICE, "price bounds");
        manager.initialize(poolKey, sqrtPriceX96);

        deal(UNI, address(this), 5_000_000e18);
        deal(USDC, address(this), 50_000_000e6);
        IERC20(UNI).approve(address(lpRouter), type(uint256).max);
        IERC20(USDC).approve(address(lpRouter), type(uint256).max);
        lpRouter.modifyLiquidity(
            poolKey,
            ModifyLiquidityParams({tickLower: MIN_TICK, tickUpper: MAX_TICK, liquidityDelta: 5e17, salt: 0}),
            ""
        );
    }

    function _assertHealthy(address account) internal view {
        Ltv current = adapter.currentLtvWad(account, market);
        assertGt(Ltv.unwrap(current), 0, "ltv positive");
        assertLt(Ltv.unwrap(current), UNI_LIQUIDATE_CF, "ltv under liquidation");
    }

    function _assertNoDust(address account) internal view {
        assertEq(IERC20(UNI).balanceOf(account), 0, "account holds no loose UNI");
        assertEq(IERC20(USDC).balanceOf(account), 0, "account holds no loose USDC");
        assertEq(IERC20(UNI).balanceOf(address(router)), 0, "router holds no loose UNI");
        assertEq(IERC20(USDC).balanceOf(address(router)), 0, "router holds no loose USDC");
    }
}
