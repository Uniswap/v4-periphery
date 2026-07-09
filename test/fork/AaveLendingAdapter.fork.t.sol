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
import {AaveLendingAdapter} from "../../src/AaveLendingAdapter.sol";
import {IPool} from "../../src/interfaces/external/aave/IPool.sol";
import {IPoolAddressesProvider} from "../../src/interfaces/external/aave/IPoolAddressesProvider.sol";
import {IPoolDataProvider} from "../../src/interfaces/external/aave/IPoolDataProvider.sol";
import {IAaveOracle} from "../../src/interfaces/external/aave/IAaveOracle.sol";
import {Market} from "../../src/types/Market.sol";
import {Ltv, toLtv} from "../../src/types/Ltv.sol";
import {PositionData} from "../../src/types/PositionData.sol";

/// @notice Full-stack mainnet-fork test of a real ETH SHORT against the live Aave v3 deployment.
///         The position supplies USDC as collateral and borrows real WETH, routed through the entire
///         margin stack at once:
///
///         MarginRouter (unlock + flash accounting + delta resolution)
///           -> V4Router swap through a real PoolManager
///           -> AaveLendingAdapter encodes real Aave v3 Pool calls
///           -> MarginAccount executes them as itself, borrowing WETH and forwarding it to the router
///           -> real Aave variable-rate interest accrual
///
///         The market pairs USDC (6 decimals) as collateral and WETH (18 decimals) as debt, so the
///         caller is long USDC and short WETH. There is no Morpho isolated market for this layout on
///         mainnet, which is the motivation for the Aave venue: shorts work on day 1 against Aave's
///         deep WETH liquidity with no new market and no lending-side seeding.
///
///         The Aave Pool, data provider, reserve receipt tokens, and collateral liquidation threshold
///         are all verified on-chain in setUp rather than trusted blindly. The only locally-deployed
///         venue is the v4 pool, which is seeded with deep full-range liquidity at the live Aave
///         oracle price so the swap leg and the lending leg agree on valuation.
contract AaveLendingAdapterForkTest is Test {
    // verified on-chain in setUp; the provider is the only address taken as given
    IPoolAddressesProvider internal constant PROVIDER =
        IPoolAddressesProvider(0x2f39d218133AFaB8F2B819B1066c7E434Ad94E9e);
    address internal constant EXPECTED_POOL = 0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2;
    address internal constant EXPECTED_DATA_PROVIDER = 0x0a16f2FCC0D44FaE41cc54e079281D84A363bECD;

    address internal constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address internal constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    address internal constant EXPECTED_A_USDC = 0x98C23E9d8f34FEFb1B7BD6a91B7FF122F4e16F5c;
    address internal constant EXPECTED_V_DEBT_USDC = 0x72E95b8931767C79bA4EeE721354d6E99a61D004;
    address internal constant EXPECTED_A_WETH = 0x4d5F47FA6A74757f35C14fD3a6Ef8E3C9BC514E8;
    address internal constant EXPECTED_V_DEBT_WETH = 0xeA51d7853EEFb32b6ee06b1C12E6dcCA88Be0fFE;

    // USDC liquidation threshold on the live reserve, in basis points (78%).
    uint256 internal constant USDC_LIQ_THRESHOLD_BPS = 7800;
    uint256 internal constant WAD = 1e18;
    uint256 internal constant BPS = 1e4;

    // canonical Permit2, identical address on every chain (unused here; pre-fund equity path is taken)
    address internal constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    uint256 internal constant FORK_BLOCK = 25_319_047;

    // full range for tickSpacing 60 (matches the shared routing helpers)
    int24 internal constant MIN_TICK = -887_220;
    int24 internal constant MAX_TICK = 887_220;
    uint24 internal constant POOL_FEE = 3000;
    int24 internal constant TICK_SPACING = 60;

    PoolManager internal manager;
    PoolModifyLiquidityTest internal lpRouter;
    AaveLendingAdapter internal adapter;
    MarginRouter internal router;

    Market internal market;
    PoolKey internal poolKey;

    // live Aave oracle prices (USD base, 8 decimals), read in setUp.
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

        // the full margin stack, wired to the live Aave Pool, canonical Permit2, and WETH9
        address impl = address(new MarginAccount());
        router = new MarginRouter(
            IPoolManager(address(manager)), IAllowanceTransfer(PERMIT2), IWETH9(WETH), impl, address(this)
        );
        router.setAdapterAllowed(adapter, true);
    }

    /// @notice Proves a real ETH short composes across a full lifecycle against live Aave v3: open a
    ///         USDC-collateralized WETH borrow, accrue variable-rate interest, partially delever, then
    ///         fully unwind. Each stage reads the real position state through the adapter and the live
    ///         receipt tokens, so the assertions exercise the read path on the live protocol.
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
        assertGt(debt, 0, "open: WETH debt drawn against the real Aave market");

        // the live aToken / variable debt token balances must agree with the adapter read
        assertApproxEqAbs(IERC20(EXPECTED_A_USDC).balanceOf(account), collateral, 1, "open: aUSDC == collateral");
        assertEq(IERC20(EXPECTED_V_DEBT_WETH).balanceOf(account), debt, "open: variableDebtWETH == debt");

        // healthy: LTV positive and below the collateral's liquidation threshold
        Ltv current = adapter.currentLtvWad(account, market);
        assertGt(Ltv.unwrap(current), 0, "open: ltv positive");
        assertLt(Ltv.unwrap(current), Ltv.unwrap(adapter.maxLtvWad(market)), "open: ltv under max");

        // describePosition returns the same values as the individual getters, in a single call
        PositionData memory snapshot = adapter.describePosition(account, market);
        assertEq(snapshot.collateralAmount, collateral, "describe: collateral matches positionOf");
        assertEq(snapshot.debtAmount, debt, "describe: debt matches positionOf");
        assertEq(Ltv.unwrap(snapshot.currentLtv), Ltv.unwrap(current), "describe: currentLtv matches");
        assertEq(Ltv.unwrap(snapshot.maxLtv), Ltv.unwrap(adapter.maxLtvWad(market)), "describe: maxLtv matches");
        assertGt(snapshot.healthFactorWad, 1e18, "describe: healthy position has HF > 1");

        _assertNoDust(account);
    }

    /// @notice Warp a day and prove the WETH debt grew purely from live Aave variable-rate accrual.
    function _stageAccrueInterest(address account) internal {
        uint256 debtBefore = IERC20(EXPECTED_V_DEBT_WETH).balanceOf(account);
        vm.warp(block.timestamp + 1 days);
        uint256 debtAfter = IERC20(EXPECTED_V_DEBT_WETH).balanceOf(account);
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
    ///         max-repay path, withdraw all USDC collateral, and return the residual USDC to the
    ///         caller. Asserts the live variable debt token and aToken both hit exactly zero (no dust)
    ///         and a positive residual is returned.
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

        assertEq(IERC20(EXPECTED_V_DEBT_WETH).balanceOf(account), 0, "close: variable WETH debt fully repaid");
        assertEq(IERC20(EXPECTED_A_USDC).balanceOf(account), 0, "close: all USDC collateral withdrawn");

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

    /// @notice Deploys the adapter against the live provider and verifies on-chain that it resolved the
    ///         expected Pool and data provider, that the USDC/WETH reserve receipt tokens match the
    ///         expected addresses, and that `maxLtvWad` decodes the USDC liquidation threshold (not the
    ///         `ltv` field). Cross-checks the threshold against the live reserve configuration.
    function _deployAndVerifyAdapter() internal {
        adapter = new AaveLendingAdapter(PROVIDER, address(this));

        assertEq(address(adapter.pool()), EXPECTED_POOL, "resolved Aave Pool");
        assertEq(address(adapter.dataProvider()), EXPECTED_DATA_PROVIDER, "resolved Aave data provider");

        // reserve receipt tokens match the expected live addresses
        (address aUsdc,, address vUsdc) = adapter.dataProvider().getReserveTokensAddresses(USDC);
        (address aWeth,, address vWeth) = adapter.dataProvider().getReserveTokensAddresses(WETH);
        assertEq(aUsdc, EXPECTED_A_USDC, "aUSDC address");
        assertEq(vUsdc, EXPECTED_V_DEBT_USDC, "variableDebtUSDC address");
        assertEq(aWeth, EXPECTED_A_WETH, "aWETH address");
        assertEq(vWeth, EXPECTED_V_DEBT_WETH, "variableDebtWETH address");

        adapter.setMarket(market.collateral, market.debt, true);

        // maxLtvWad must decode the liquidation threshold (Morpho's lltv analog), not the max-borrow
        // ltv. Cross-check against the live reserve configuration so a field mixup fails loudly.
        (,, uint256 liqThreshold,,,,,,,) = adapter.dataProvider().getReserveConfigurationData(USDC);
        assertEq(liqThreshold, USDC_LIQ_THRESHOLD_BPS, "live USDC liquidation threshold");
        assertEq(Ltv.unwrap(adapter.maxLtvWad(market)), USDC_LIQ_THRESHOLD_BPS * WAD / BPS, "maxLtvWad uses threshold");
        assertEq(Ltv.unwrap(adapter.maxLtvWad(market)), 0.78e18, "maxLtvWad == 0.78e18");
    }

    /// @notice Reads the live Aave oracle prices for USDC and WETH (USD base, 8 decimals).
    function _readOraclePrices() internal {
        IAaveOracle oracle = IAaveOracle(PROVIDER.getPriceOracle());
        usdcPriceBase = oracle.getAssetPrice(USDC);
        wethPriceBase = oracle.getAssetPrice(WETH);
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

        // deal generously (covers any plausible WETH price at the fork block) and seed a large
        // full-range position: depth far exceeds the few-thousand-USDC swaps the lifecycle performs
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
    ///         USDC_raw is `usdcPriceBase * 1e18 / (wethPriceBase * 1e6) = usdcPriceBase * 1e12 /
    ///         wethPriceBase`. sqrtPriceX96 = sqrt(v4price * 2^192).
    function _sqrtPriceX96FromOracle() internal view returns (uint160 sqrtPriceX96) {
        uint256 numerator = usdcPriceBase * 1e12;
        uint256 priceX192 = FullMath.mulDiv(numerator, uint256(1) << 192, wethPriceBase);
        sqrtPriceX96 = uint160(FixedPointMathLib.sqrt(priceX192));
        require(sqrtPriceX96 > TickMath.MIN_SQRT_PRICE && sqrtPriceX96 < TickMath.MAX_SQRT_PRICE, "price bounds");
    }

    /// @notice A generous WETH `maxDebtIn` cap for buying `usdcAmount` of USDC collateral: the oracle
    ///         WETH cost of that USDC plus a 10% slippage/fee buffer. Derived from the oracle price, a
    ///         quote, not from spot, mirroring how an integrator would size the cap.
    function _maxDebtForUsdc(uint256 usdcAmount) internal view returns (uint128) {
        // WETH_raw cost = usdcAmount(6d) * usdcPriceBase / (wethPriceBase / 1e18) / 1e6
        //               = usdcAmount * usdcPriceBase * 1e18 / (wethPriceBase * 1e6)
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
