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
import {MarginRouter} from "../../src/MarginRouter.sol";
import {IMarginRouter} from "../../src/interfaces/IMarginRouter.sol";
import {MarginAccount} from "../../src/MarginAccount.sol";
import {AaveV4LendingAdapter} from "../../src/AaveV4LendingAdapter.sol";
import {ISpoke} from "../../src/interfaces/external/aave-v4/ISpoke.sol";
import {IAaveOracle} from "../../src/interfaces/external/aave-v4/IAaveOracle.sol";
import {Market} from "../../src/types/Market.sol";
import {Ltv, toLtv} from "../../src/types/Ltv.sol";

/// @notice Full-stack mainnet-fork test of a real ETH SHORT against the live Aave v4 deployment. The
///         position supplies USDC as collateral and borrows real WETH on the Aave v4 Main Spoke,
///         routed through the entire margin stack at once:
///
///         MarginRouter (unlock + flash accounting + delta resolution)
///           -> V4Router swap through a real PoolManager
///           -> AaveV4LendingAdapter encodes real Aave v4 Spoke calls
///           -> MarginAccount executes them as itself, supplying + enabling collateral via the Spoke
///              multicall, borrowing WETH and forwarding it to the router
///           -> real Aave v4 variable-rate + premium accrual
///
///         The market pairs USDC (6 decimals, reserveId 7) as collateral and WETH (18 decimals,
///         reserveId 0) as debt, so the caller is long USDC and short WETH. Unlike Aave v3, the v4
///         oracle is reserveId-keyed and supply does not auto-enable collateral; both are exercised
///         here. The Spoke, Hub, oracle, reserve underlyings, and collateral factor are all verified
///         on-chain in setUp. The only locally-deployed venue is the v4 pool, seeded with deep
///         full-range liquidity at the live Aave oracle price so the swap and lending legs agree.
contract AaveV4LendingAdapterForkTest is Test {
    // canonical Aave v4 mainnet addresses (bgd-labs/aave-address-book), verified on-chain in setUp
    address internal constant MAIN_SPOKE = 0x94e7A5dCbE816e498b89aB752661904E2F56c485;
    address internal constant CORE_HUB = 0xCca852Bc40e560adC3b1Cc58CA5b55638ce826c9;
    address internal constant EXPECTED_ORACLE = 0x99B2B6CEa9C3D2fd8F4d90f86741C44B212a6127;

    address internal constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address internal constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    // reserve ids on the Main Spoke
    uint256 internal constant WETH_RESERVE_ID = 0;
    uint256 internal constant USDC_RESERVE_ID = 7;
    // USDC collateral factor on the live reserve, in basis points (78%).
    uint256 internal constant USDC_CF_BPS = 7800;
    uint256 internal constant WAD = 1e18;
    uint256 internal constant BPS = 1e4;

    // canonical Permit2, identical address on every chain (unused here; pre-fund equity path is taken)
    address internal constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    uint256 internal constant FORK_BLOCK = 25_330_047;

    // full range for tickSpacing 60 (matches the shared routing helpers)
    int24 internal constant MIN_TICK = -887_220;
    int24 internal constant MAX_TICK = 887_220;
    uint24 internal constant POOL_FEE = 3000;
    int24 internal constant TICK_SPACING = 60;

    PoolManager internal manager;
    PoolModifyLiquidityTest internal lpRouter;
    AaveV4LendingAdapter internal adapter;
    MarginRouter internal router;

    Market internal market;
    PoolKey internal poolKey;

    // live Aave v4 oracle prices (USD base, 8 decimals), read in setUp.
    uint256 internal usdcPriceBase;
    uint256 internal wethPriceBase;

    function setUp() public {
        string memory rpc = vm.envOr("MAINNET_RPC_URL", string(""));
        vm.skip(bytes(rpc).length == 0);
        if (bytes(rpc).length == 0) return;
        vm.createSelectFork(rpc, FORK_BLOCK);

        // the short market: USDC collateral, WETH debt (long USDC, short WETH)
        market = Market({collateral: Currency.wrap(USDC), debt: Currency.wrap(WETH)});

        _deployAndVerifyAdapter();
        _readOraclePrices();

        // a real, freshly-deployed v4 PoolManager and a USDC/WETH pool priced at the Aave oracle
        manager = new PoolManager(address(this));
        lpRouter = new PoolModifyLiquidityTest(IPoolManager(address(manager)));
        _initAndSeedPool();

        // the full margin stack, wired to the live Aave v4 Spoke, canonical Permit2, and WETH9
        address impl = address(new MarginAccount());
        router = new MarginRouter(
            IPoolManager(address(manager)), IAllowanceTransfer(PERMIT2), IWETH9(WETH), impl, address(this)
        );
        router.setAdapterAllowed(adapter, true);
    }

    /// @notice Proves a real ETH short composes across a full lifecycle against live Aave v4: open a
    ///         USDC-collateralized WETH borrow, accrue interest, partially delever, then fully unwind.
    ///         Each stage reads the real position state through the adapter and the live Spoke, so the
    ///         assertions exercise the read path on the live protocol.
    function test_fork_shortEth_fullLifecycle() public {
        address account = router.accountOf(address(this), 0);

        _stageOpen(account);
        _stageAccrueInterest(account);
        _stageDecrease(account);
        _stageClose(account);
    }

    // -------------------------------------------------------------------------
    // Lifecycle stages (split to keep locals-per-frame low: tests compile without via_ir)
    // -------------------------------------------------------------------------

    /// @notice Open a ~2x short: 2000 USDC equity buys 2000 USDC of collateral funded by borrowed WETH,
    ///         landing collateral at ~4000 USDC. Debt is positive WETH, within the maxDebtIn cap, and
    ///         the position is healthy. The settle proof: neither the account nor the router holds any
    ///         loose USDC or WETH afterward.
    function _stageOpen(address account) internal {
        // pre-fund the account with 2000 USDC equity; equity=0 in params avoids the Permit2 pull
        deal(USDC, account, 2000e6);
        _openCall(2000e6, _maxDebtForUsdc(2000e6));

        (uint256 collateral, uint256 debt) = adapter.positionOf(account, market);
        _log("open", account);
        assertApproxEqAbs(collateral, 4000e6, 1e6, "open: collateral = equity + bought");
        assertGt(debt, 0, "open: WETH debt drawn against the real Aave v4 market");

        // the live Spoke position must agree with the adapter read; the supply must be enabled as
        // collateral (otherwise the borrow's health check would have reverted)
        assertApproxEqAbs(
            ISpoke(MAIN_SPOKE).getUserSuppliedAssets(USDC_RESERVE_ID, account),
            collateral,
            1,
            "open: supplied == collateral"
        );
        assertEq(ISpoke(MAIN_SPOKE).getUserTotalDebt(WETH_RESERVE_ID, account), debt, "open: spoke debt == debt");

        // healthy: LTV positive and below the collateral's factor
        Ltv current = adapter.currentLtvWad(account, market);
        assertGt(Ltv.unwrap(current), 0, "open: ltv positive");
        assertLt(Ltv.unwrap(current), Ltv.unwrap(adapter.maxLtvWad(market)), "open: ltv under max");

        _assertNoDust(account);
    }

    /// @notice Warp a day and prove the WETH debt grew purely from live Aave v4 accrual.
    function _stageAccrueInterest(address account) internal {
        uint256 debtBefore = ISpoke(MAIN_SPOKE).getUserTotalDebt(WETH_RESERVE_ID, account);
        vm.warp(block.timestamp + 1 days);
        uint256 debtAfter = ISpoke(MAIN_SPOKE).getUserTotalDebt(WETH_RESERVE_ID, account);
        _log("after 1d accrual", account);
        assertGt(debtAfter, debtBefore, "accrual: WETH debt grew from real interest");
    }

    /// @notice Partially delever: repay a fraction of the WETH debt by selling USDC collateral. Debt
    ///         and collateral both shrink but stay positive, and the resulting LTV passes the bound.
    function _stageDecrease(address account) internal {
        (uint256 collBefore, uint256 debtBefore) = adapter.positionOf(account, market);

        // repay a quarter of the current WETH debt; cap the USDC spent generously
        uint256 debtToRepay = debtBefore / 4;
        router.decreasePosition(
            IMarginRouter.DecreaseParams({
                adapter: adapter,
                market: market,
                poolKey: poolKey,
                debtToRepay: debtToRepay,
                maxCollateralIn: 2000e6,
                minHopPriceX36: 0,
                maxLtvAfter: toLtv(0.7e18),
                subId: 0,
                deadline: block.timestamp + 1 hours
            })
        );

        (uint256 collAfter, uint256 debtAfter) = adapter.positionOf(account, market);
        _log("decrease", account);
        assertLt(debtAfter, debtBefore, "decrease: WETH debt reduced");
        assertGt(debtAfter, 0, "decrease: position still open");
        assertLt(collAfter, collBefore, "decrease: USDC collateral sold to fund repay");
        assertGt(collAfter, 0, "decrease: collateral remains");

        Ltv current = adapter.currentLtvWad(account, market);
        assertGt(Ltv.unwrap(current), 0, "decrease: ltv positive");
        assertLt(Ltv.unwrap(current), Ltv.unwrap(adapter.maxLtvWad(market)), "decrease: ltv under max");

        _assertNoDust(account);
    }

    /// @notice Full unwind: sell USDC collateral to buy back the full WETH debt, repay it with the
    ///         max-repay path, withdraw all USDC collateral (delivered to the account by the Spoke and
    ///         forwarded to the router), and return the residual USDC to the caller. Asserts the live
    ///         Spoke debt and supply both hit exactly zero and a positive residual is returned.
    function _stageClose(address account) internal {
        uint256 usdcBefore = IERC20(USDC).balanceOf(address(this));

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

        uint256 residual = IERC20(USDC).balanceOf(address(this)) - usdcBefore;
        _log("close", account);
        console2.log("residual USDC returned:", residual);

        assertEq(ISpoke(MAIN_SPOKE).getUserTotalDebt(WETH_RESERVE_ID, account), 0, "close: WETH debt fully repaid");
        assertEq(
            ISpoke(MAIN_SPOKE).getUserSuppliedAssets(USDC_RESERVE_ID, account),
            0,
            "close: all USDC collateral withdrawn"
        );

        (uint256 collateral, uint256 debt) = adapter.positionOf(account, market);
        assertEq(debt, 0, "close: adapter agrees debt is zero");
        assertEq(collateral, 0, "close: adapter agrees collateral is zero");

        assertGt(residual, 0, "close: residual USDC returned to caller");
        _assertNoDust(account);
    }

    // -------------------------------------------------------------------------
    // Thin router-call wrappers (isolate inline param-struct construction in their own frames)
    // -------------------------------------------------------------------------

    /// @notice Builds and submits an open buying `buy` USDC of collateral, capped at `maxDebtIn` WETH.
    function _openCall(uint128 buy, uint128 maxDebtIn) internal {
        router.openPosition(
            IMarginRouter.OpenParams({
                adapter: adapter,
                market: market,
                poolKey: poolKey,
                equity: 0,
                collateralToBuy: buy,
                maxDebtIn: maxDebtIn,
                minHopPriceX36: 0,
                subId: 0,
                deadline: block.timestamp + 1 hours
            })
        );
    }

    // -------------------------------------------------------------------------
    // Setup + verification helpers
    // -------------------------------------------------------------------------

    /// @notice Deploys the adapter against the live Main Spoke and verifies on-chain that the WETH and
    ///         USDC reserves resolve to the expected underlyings on the Core Hub, the oracle matches,
    ///         and `maxLtvWad` decodes the USDC collateral factor. Registers the short market.
    function _deployAndVerifyAdapter() internal {
        adapter = new AaveV4LendingAdapter(ISpoke(MAIN_SPOKE), address(this));
        assertEq(adapter.lendingProtocol(), MAIN_SPOKE, "lendingProtocol == Main Spoke");
        assertEq(ISpoke(MAIN_SPOKE).ORACLE(), EXPECTED_ORACLE, "spoke oracle");

        ISpoke.Reserve memory wethReserve = ISpoke(MAIN_SPOKE).getReserve(WETH_RESERVE_ID);
        ISpoke.Reserve memory usdcReserve = ISpoke(MAIN_SPOKE).getReserve(USDC_RESERVE_ID);
        assertEq(wethReserve.underlying, WETH, "reserve 0 underlying == WETH");
        assertEq(usdcReserve.underlying, USDC, "reserve 7 underlying == USDC");
        assertEq(wethReserve.hub, CORE_HUB, "WETH reserve on Core Hub");
        assertEq(usdcReserve.hub, CORE_HUB, "USDC reserve on Core Hub");

        // the short needs borrowable WETH and usable USDC collateral
        assertTrue(ISpoke(MAIN_SPOKE).getReserveConfig(WETH_RESERVE_ID).borrowable, "WETH borrowable");
        assertFalse(ISpoke(MAIN_SPOKE).getReserveConfig(USDC_RESERVE_ID).paused, "USDC not paused");

        adapter.setMarket(market.collateral, market.debt, USDC_RESERVE_ID, WETH_RESERVE_ID, true);

        // maxLtvWad must decode the USDC collateral factor (78%)
        assertEq(Ltv.unwrap(adapter.maxLtvWad(market)), USDC_CF_BPS * WAD / BPS, "maxLtvWad uses collateral factor");
        assertEq(Ltv.unwrap(adapter.maxLtvWad(market)), 0.78e18, "maxLtvWad == 0.78e18");
    }

    /// @notice Reads the live Aave v4 oracle prices for the WETH and USDC reserves (USD base, 8
    ///         decimals). The v4 oracle is reserveId-keyed, not asset-keyed.
    function _readOraclePrices() internal {
        IAaveOracle oracle = IAaveOracle(ISpoke(MAIN_SPOKE).ORACLE());
        assertEq(oracle.decimals(), 8, "oracle base decimals == 8");
        usdcPriceBase = oracle.getReservePrice(USDC_RESERVE_ID);
        wethPriceBase = oracle.getReservePrice(WETH_RESERVE_ID);
        assertGt(usdcPriceBase, 0, "USDC oracle price positive");
        assertGt(wethPriceBase, 0, "WETH oracle price positive");
        console2.log("oracle USDC price (8d):", usdcPriceBase);
        console2.log("oracle WETH price (8d):", wethPriceBase);
    }

    /// @notice Initializes the USDC/WETH pool at the live Aave oracle price and seeds deep full-range
    ///         liquidity using dealt tokens, so the swap leg values WETH the same way Aave does.
    function _initAndSeedPool() internal {
        // USDC (0xA0..) sorts below WETH (0xC0..), so currency0 = USDC, currency1 = WETH
        require(USDC < WETH, "currency ordering");
        poolKey = PoolKey({
            currency0: Currency.wrap(USDC),
            currency1: Currency.wrap(WETH),
            fee: POOL_FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(0))
        });

        manager.initialize(poolKey, _sqrtPriceX96FromOracle());

        // deal generously and seed a large full-range position: depth far exceeds the few-thousand-USDC
        // swaps the lifecycle performs
        deal(USDC, address(this), 100_000_000_000e6);
        deal(WETH, address(this), 1_000_000 ether);
        IERC20(USDC).approve(address(lpRouter), type(uint256).max);
        IERC20(WETH).approve(address(lpRouter), type(uint256).max);
        lpRouter.modifyLiquidity(
            poolKey,
            ModifyLiquidityParams({tickLower: MIN_TICK, tickUpper: MAX_TICK, liquidityDelta: 1e18, salt: 0}),
            ""
        );
    }

    /// @notice The sqrtPriceX96 for the USDC/WETH pool derived from the live Aave oracle. The v4 price
    ///         is token1/token0 = WETH_raw/USDC_raw. One USDC_raw (1e6) is worth `usdcPriceBase` USD;
    ///         one WETH_raw (1e18) is worth `wethPriceBase` USD. So the WETH_raw value-equal to one
    ///         USDC_raw is `usdcPriceBase * 1e12 / wethPriceBase`. sqrtPriceX96 = sqrt(v4price * 2^192).
    function _sqrtPriceX96FromOracle() internal view returns (uint160 sqrtPriceX96) {
        uint256 numerator = usdcPriceBase * 1e12;
        uint256 priceX192 = FullMath.mulDiv(numerator, uint256(1) << 192, wethPriceBase);
        sqrtPriceX96 = uint160(FixedPointMathLib.sqrt(priceX192));
        require(sqrtPriceX96 > TickMath.MIN_SQRT_PRICE && sqrtPriceX96 < TickMath.MAX_SQRT_PRICE, "price bounds");
    }

    /// @notice A generous WETH `maxDebtIn` cap for buying `usdcAmount` of USDC collateral: the oracle
    ///         WETH cost of that USDC plus a 10% slippage/fee buffer.
    function _maxDebtForUsdc(uint256 usdcAmount) internal view returns (uint128) {
        uint256 wethCost = FullMath.mulDiv(usdcAmount * 1e12, usdcPriceBase, wethPriceBase);
        return uint128(wethCost * 110 / 100);
    }

    // -------------------------------------------------------------------------
    // Assertion + logging helpers
    // -------------------------------------------------------------------------

    /// @notice Asserts neither the account nor the router retains loose USDC or WETH.
    function _assertNoDust(address account) internal view {
        assertEq(IERC20(USDC).balanceOf(account), 0, "account holds no loose USDC");
        assertEq(IERC20(WETH).balanceOf(account), 0, "account holds no loose WETH");
        assertEq(IERC20(USDC).balanceOf(address(router)), 0, "router holds no loose USDC");
        assertEq(IERC20(WETH).balanceOf(address(router)), 0, "router holds no loose WETH");
    }

    /// @notice Logs the position's collateral, debt, and current LTV at a lifecycle stage.
    function _log(string memory stage, address account) internal view {
        (uint256 collateral, uint256 debt) = adapter.positionOf(account, market);
        console2.log(stage);
        console2.log("  collateral (USDC):", collateral);
        console2.log("  debt (WETH wei):", debt);
        console2.log("  ltv (WAD):", Ltv.unwrap(adapter.currentLtvWad(account, market)));
    }
}
