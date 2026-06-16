// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console2} from "forge-std/Test.sol";

import {IMorpho, MarketParams} from "morpho-blue/interfaces/IMorpho.sol";
import {MarketParamsLib} from "morpho-blue/libraries/MarketParamsLib.sol";

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
import {MorphoLendingAdapter} from "../../src/MorphoLendingAdapter.sol";
import {AaveLendingAdapter} from "../../src/AaveLendingAdapter.sol";
import {IPoolAddressesProvider} from "../../src/interfaces/external/aave/IPoolAddressesProvider.sol";
import {IAaveOracle} from "../../src/interfaces/external/aave/IAaveOracle.sol";
import {Market} from "../../src/types/Market.sol";
import {Ltv} from "../../src/types/Ltv.sol";

/// @notice Mainnet-fork test of one owner running a delta-neutral HEDGE across TWO different lending
///         venues at once, both legs under the SAME subId, so both positions live in ONE shared
///         MarginAccount. This is the cross-venue hedge with the subId collapsed to a single value:
///         because `accountOf(owner, subId)` is deterministic in (owner, manager, subId), reusing the
///         same subId for both legs resolves them to the SAME account.
///
///         Long leg  (subId 0): collateral WETH, debt USDC on live Morpho Blue -> long the WETH.
///         Short leg (subId 0): collateral USDC, debt WETH on live Aave v3   -> short the WETH.
///
///         Both legs are of matched ETH notional, so the long's +WETH collateral and the short's
///         -WETH debt net to ~zero ETH delta within swap slippage. The point this exercises is that a
///         single shared account can hold a Morpho long (collateral WETH, debt USDC) and an Aave short
///         (collateral USDC, debt WETH) at the same time, and the two are kept apart by VENUE, not by
///         subId: Morpho tracks the account's position on its own internal ledger and Aave tracks it
///         on its aToken/variableDebt receipts, and neither nets against the other. Closing the Morpho
///         long does not touch the Aave short of the SAME account, proving venue isolation within one
///         shared account.
///
///         The Morpho market, the Aave Pool, data provider, reserve receipt tokens, equity tokens
///         (WETH/USDC), Permit2, and WETH9 are all live mainnet contracts. Only the v4 pool is local:
///         one deep full-range WETH/USDC pool seeded at the live oracle price. The long buys WETH
///         selling USDC and the short buys USDC selling WETH in that same pool, opposite directions.
///         Direction is set purely by the market pairing; there is no Direction enum.
contract MarginRouterSameSubIdHedgeForkTest is Test {
    using MarketParamsLib for MarketParams;

    // live Morpho Blue singleton and its WETH/USDC market (verified on-chain in setUp)
    IMorpho internal constant MORPHO = IMorpho(0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb);
    address internal constant MORPHO_ORACLE = 0xdC6fd5831277c693b1054e19E94047cB37c77615;
    address internal constant MORPHO_IRM = 0x870aC11D48B15DB9a138Cf899d20F13F79Ba00BC;
    uint256 internal constant MORPHO_LLTV = 0.86e18;

    // live Aave v3 PoolAddressesProvider (verified on-chain in setUp); resolves Pool, data provider, oracle
    IPoolAddressesProvider internal constant AAVE_PROVIDER =
        IPoolAddressesProvider(0x2f39d218133AFaB8F2B819B1066c7E434Ad94E9e);
    address internal constant EXPECTED_AAVE_POOL = 0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2;
    address internal constant EXPECTED_AAVE_DATA_PROVIDER = 0x0a16f2FCC0D44FaE41cc54e079281D84A363bECD;

    // live Aave v3 reserve receipt tokens for the short leg (verified on-chain in setUp)
    address internal constant EXPECTED_A_USDC = 0x98C23E9d8f34FEFb1B7BD6a91B7FF122F4e16F5c;
    address internal constant EXPECTED_V_DEBT_WETH = 0xeA51d7853EEFb32b6ee06b1C12E6dcCA88Be0fFE;

    address internal constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address internal constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

    // canonical Permit2, identical address on every chain (unused: equity is pre-funded into accounts)
    address internal constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    uint256 internal constant FORK_BLOCK = 25_319_047;

    // full range for tickSpacing 60 (matches the shared routing helpers)
    int24 internal constant MIN_TICK = -887_220;
    int24 internal constant MAX_TICK = 887_220;
    uint24 internal constant POOL_FEE = 3000;
    int24 internal constant TICK_SPACING = 60;

    // both legs of the hedge share this subId, so both resolve to the same MarginAccount
    uint256 internal constant SHARED_SUB_ID = 0;

    // matched ETH notional for both legs of the cross-venue hedge
    uint128 internal constant LONG_BUY_WETH = 1e18; // long: 1 WETH equity + 1 WETH bought = ~2 WETH
    uint256 internal constant TARGET_WETH = 2e18; // gross ETH exposure each leg targets

    PoolManager internal manager;
    PoolModifyLiquidityTest internal lpRouter;
    MorphoLendingAdapter internal morphoAdapter;
    AaveLendingAdapter internal aaveAdapter;
    MarginRouter internal router;

    MarketParams internal morphoMarketParams; // the live Morpho WETH/USDC market for the long leg
    Market internal longMarket; // Morpho: collateral WETH, debt USDC -> long WETH
    Market internal shortMarket; // Aave: collateral USDC, debt WETH -> short WETH
    PoolKey internal poolKey;
    address internal owner;

    // live Aave oracle prices (USD base, 8 decimals), read in setUp and used to seed the pool and
    // to size the short so its WETH debt matches the long's WETH collateral
    uint256 internal usdcPriceBase;
    uint256 internal wethPriceBase;

    // snapshot of the Aave short leg, kept in storage so the venue-isolation check does not pile
    // locals onto one stack frame (tests compile without via_ir)
    uint256 internal _shortCollSnapshot;
    uint256 internal _shortDebtSnapshot;

    /// @dev Accept ETH only in case the liquidity router refunds native dust; the pool is ERC20/ERC20
    ///      so this should not fire, but it keeps the seed step robust.
    receive() external payable {}

    function setUp() public {
        string memory rpc = vm.envOr("MAINNET_RPC_URL", string(""));
        vm.skip(bytes(rpc).length == 0);
        if (bytes(rpc).length == 0) return;
        vm.createSelectFork(rpc, FORK_BLOCK);

        owner = address(this);

        // the long lives on Morpho (WETH collateral / USDC debt); the short on Aave (USDC / WETH)
        longMarket = Market({collateral: Currency.wrap(WETH), debt: Currency.wrap(USDC)});
        shortMarket = Market({collateral: Currency.wrap(USDC), debt: Currency.wrap(WETH)});

        _deployAndVerifyAdapters();
        _readOraclePrices();

        // a real, freshly-deployed v4 PoolManager and a USDC/WETH pool priced at the live oracle
        manager = new PoolManager(address(this));
        lpRouter = new PoolModifyLiquidityTest(IPoolManager(address(manager)));
        _initAndSeedPool();

        // the full margin stack, wired to live Morpho, live Aave, canonical Permit2, and WETH9;
        // both adapters are allowlisted so one router can drive positions on either venue
        address impl = address(new MarginAccount());
        router = new MarginRouter(
            IPoolManager(address(manager)), IAllowanceTransfer(PERMIT2), IWETH9(WETH), impl, address(this)
        );
        router.setAdapterAllowed(morphoAdapter, true);
        router.setAdapterAllowed(aaveAdapter, true);
    }

    /// @notice Proves one owner can run a LONG on Morpho and a SHORT on Aave of matched ETH size in
    ///         ONE shared MarginAccount (both legs under the same subId), that the pair is
    ///         delta-neutral within swap slippage, and that closing one venue's leg does not disturb
    ///         the other's even though both share the account.
    function test_fork_sameSubId_sharedAccount_hedge() public {
        // both legs use the same subId, so accountOf resolves them to a SINGLE shared account
        address account = router.accountOf(owner, SHARED_SUB_ID);

        // opening the long deploys the account's MarginAccount clone (it does not exist until first use)
        _openLongMorpho(account);
        // the short reuses the SAME subId, so it lands in the SAME account; no second clone is created
        _openShortAave(account);

        // (1) the single shared account is what both legs used, owned by `owner` and managed by router
        assertEq(router.accountOf(owner, SHARED_SUB_ID), account, "both legs resolve to the one account");
        assertEq(MarginAccount(account).owner(), owner, "shared account owner is owner");
        assertEq(MarginAccount(account).manager(), address(router), "shared account managed by router");

        // (2) the Morpho long is the expected isolated position; the Morpho read sees only the Morpho leg
        _assertLongHealthy(account);
        // (3) the Aave short is the expected isolated position; the Aave read sees only the Aave leg
        _assertShortHealthy(account);

        // (4) the +WETH (Morpho long collateral) and -WETH (Aave short debt) match within slippage:
        //     the shared account is delta-neutral across the two venues
        _assertDeltaNeutral(account);

        // (5) venue isolation within one account: closing the Morpho long leaves the Aave short of the
        //     SAME account untouched
        _snapshotShort(account);
        _closeLongAndAssertUnwound(account);
        _assertShortUnchanged(account);

        // and the Aave short of the same account then closes cleanly on its own
        _closeShortAndAssertUnwound(account);
    }

    // -------------------------------------------------------------------------
    // Per-leg open helpers (split to keep locals-per-frame low: tests compile without via_ir)
    // -------------------------------------------------------------------------

    /// @notice Opens the LONG on Morpho under the shared subId: pre-fund 1 WETH equity, then buy +1
    ///         WETH funded by USDC debt, landing ~2 WETH collateral against a USDC loan on the live
    ///         Morpho market.
    function _openLongMorpho(address account) internal {
        deal(WETH, account, 1 ether);
        router.openPosition(
            IMarginRouter.OpenParams({
                adapter: morphoAdapter,
                market: longMarket,
                poolKey: poolKey,
                equity: 0,
                collateralToBuy: LONG_BUY_WETH,
                maxDebtIn: _maxUsdcForWeth(LONG_BUY_WETH),
                minHopPriceX36: 0,
                subId: SHARED_SUB_ID,
                deadline: block.timestamp + 1 hours
            })
        );
        _logLong("long open (Morpho, shared subId)", account);
    }

    /// @notice Opens the SHORT on Aave under the SAME shared subId (the same account): size the bought
    ///         USDC collateral to ~2 WETH-worth so the resulting WETH debt matches the Morpho long's
    ///         ~2 WETH collateral. Pre-fund an equal USDC equity so total collateral is ~2x (healthy).
    function _openShortAave(address account) internal {
        uint128 buyUsdc = _usdcWorthOfWeth(TARGET_WETH); // ~2 WETH worth of USDC collateral to buy
        deal(USDC, account, buyUsdc); // equal USDC equity -> total collateral ~= 2 * buyUsdc
        router.openPosition(
            IMarginRouter.OpenParams({
                adapter: aaveAdapter,
                market: shortMarket,
                poolKey: poolKey,
                equity: 0,
                collateralToBuy: buyUsdc,
                maxDebtIn: 2.2e18, // generous WETH cap (> ~2 WETH plus slippage/fees)
                minHopPriceX36: 0,
                subId: SHARED_SUB_ID,
                deadline: block.timestamp + 1 hours
            })
        );
        _logShort("short open (Aave, shared subId)", account);
    }

    // -------------------------------------------------------------------------
    // Per-leg assertion helpers
    // -------------------------------------------------------------------------

    /// @notice Asserts the Morpho long holds ~2 WETH collateral, a positive USDC debt, and is under
    ///         Morpho's max LTV (its LLTV). The Morpho read reflects ONLY the Morpho leg of the shared
    ///         account; the account's Aave short is invisible to Morpho.
    function _assertLongHealthy(address account) internal view {
        (uint256 collateral, uint256 debt) = morphoAdapter.positionOf(account, longMarket);
        assertApproxEqAbs(collateral, TARGET_WETH, 1, "long: collateral = equity + bought WETH");
        assertGt(debt, 0, "long: USDC debt drawn against live Morpho");

        uint256 ltv = Ltv.unwrap(morphoAdapter.currentLtvWad(account, longMarket));
        assertGt(ltv, 0, "long: ltv positive");
        assertLt(ltv, Ltv.unwrap(morphoAdapter.maxLtvWad(longMarket)), "long: ltv under Morpho max");
        _assertNoDust(account);
    }

    /// @notice Asserts the Aave short holds positive USDC collateral, a positive WETH debt, and is
    ///         under Aave's max LTV. The Aave read reflects ONLY the Aave leg of the shared account:
    ///         account-level getUserAccountData on Aave sees only the account's Aave reserves, not the
    ///         Morpho long. Cross-checks the live aUSDC and variableDebtWETH receipt tokens.
    function _assertShortHealthy(address account) internal view {
        (uint256 collateral, uint256 debt) = aaveAdapter.positionOf(account, shortMarket);
        assertGt(collateral, 0, "short: USDC collateral supplied to real Aave");
        assertGt(debt, 0, "short: WETH debt borrowed from real Aave");
        assertApproxEqAbs(IERC20(EXPECTED_A_USDC).balanceOf(account), collateral, 1, "short: aUSDC == collateral");
        assertEq(IERC20(EXPECTED_V_DEBT_WETH).balanceOf(account), debt, "short: variableDebtWETH == debt");

        uint256 ltv = Ltv.unwrap(aaveAdapter.currentLtvWad(account, shortMarket));
        assertGt(ltv, 0, "short: ltv positive");
        assertLt(ltv, Ltv.unwrap(aaveAdapter.maxLtvWad(shortMarket)), "short: ltv under Aave max");
        _assertNoDust(account);
    }

    /// @notice The heart of the cross-venue hedge in one shared account: the Morpho long's WETH
    ///         collateral (+WETH) and the Aave short's WETH debt (-WETH) match within ~2%, so the net
    ///         ETH delta is near zero. Logs the gross legs and the net so the hedge is visible, and
    ///         bounds the net at < 5% of the 2 WETH gross. The residual is pure swap slippage and fees;
    ///         the shared account is delta-neutral across the two venues within them.
    function _assertDeltaNeutral(address account) internal view {
        (uint256 longWeth,) = morphoAdapter.positionOf(account, longMarket);
        (, uint256 shortWeth) = aaveAdapter.positionOf(account, shortMarket);

        uint256 net = longWeth > shortWeth ? longWeth - shortWeth : shortWeth - longWeth;
        console2.log("hedge: Morpho long WETH collateral (+):", longWeth);
        console2.log("hedge: Aave short WETH debt         (-):", shortWeth);
        console2.log("hedge: net ETH delta (abs wei):         ", net);

        // the two ETH legs match within ~2% of each other
        assertApproxEqRel(longWeth, shortWeth, 0.02e18, "hedge: long +WETH matches short -WETH");
        // and the net is small relative to the 2 WETH gross exposure of either leg
        assertLt(net, TARGET_WETH * 5 / 100, "hedge: net ETH delta under 5% of gross");
    }

    // -------------------------------------------------------------------------
    // Venue-isolation helpers (one shared account, two venues)
    // -------------------------------------------------------------------------

    /// @notice Records the Aave short's (collateral, debt) before the Morpho long is closed, so the
    ///         close on the other venue can be proven not to disturb it even though they share an account.
    function _snapshotShort(address account) internal {
        (_shortCollSnapshot, _shortDebtSnapshot) = aaveAdapter.positionOf(account, shortMarket);
    }

    /// @notice Closes the Morpho LONG (shared subId), asserts the account's Morpho position is fully
    ///         unwound (zero debt, zero collateral) and that residual WETH was returned to the owner.
    function _closeLongAndAssertUnwound(address account) internal {
        uint256 wethBefore = IERC20(WETH).balanceOf(owner);
        router.closePosition(
            IMarginRouter.CloseParams({
                adapter: morphoAdapter,
                market: longMarket,
                poolKey: poolKey,
                maxCollateralIn: 3 ether,
                minHopPriceX36: 0,
                subId: SHARED_SUB_ID,
                deadline: block.timestamp + 1 hours
            })
        );
        uint256 residual = IERC20(WETH).balanceOf(owner) - wethBefore;

        (uint256 collateral, uint256 debt) = morphoAdapter.positionOf(account, longMarket);
        console2.log("long close (Morpho, shared subId) residual WETH:", residual);
        assertEq(debt, 0, "long close: USDC debt fully repaid");
        assertEq(collateral, 0, "long close: all WETH collateral withdrawn");
        assertGt(residual, 0, "long close: residual WETH returned to owner");
        _assertNoDust(account);
    }

    /// @notice Asserts the Aave short of the SAME account is exactly as it was before the Morpho long
    ///         was closed: the two venue positions are isolated even though they share one account.
    function _assertShortUnchanged(address account) internal view {
        (uint256 collateral, uint256 debt) = aaveAdapter.positionOf(account, shortMarket);
        assertEq(collateral, _shortCollSnapshot, "isolation: Aave short collateral untouched by Morpho close");
        assertEq(debt, _shortDebtSnapshot, "isolation: Aave short debt untouched by Morpho close");
        assertGt(debt, 0, "isolation: Aave short still open after Morpho close");
    }

    /// @notice Closes the Aave SHORT (shared subId), asserts the account's Aave position is fully
    ///         unwound (zero WETH debt, zero USDC collateral, receipt tokens at zero) and that residual
    ///         USDC went to the owner.
    function _closeShortAndAssertUnwound(address account) internal {
        uint256 usdcBefore = IERC20(USDC).balanceOf(owner);
        router.closePosition(
            IMarginRouter.CloseParams({
                adapter: aaveAdapter,
                market: shortMarket,
                poolKey: poolKey,
                maxCollateralIn: _usdcWorthOfWeth(3e18), // generous USDC cap (> ~2 WETH worth)
                minHopPriceX36: 0,
                subId: SHARED_SUB_ID,
                deadline: block.timestamp + 1 hours
            })
        );
        uint256 residual = IERC20(USDC).balanceOf(owner) - usdcBefore;

        (uint256 collateral, uint256 debt) = aaveAdapter.positionOf(account, shortMarket);
        console2.log("short close (Aave, shared subId) residual USDC:", residual);
        assertEq(IERC20(EXPECTED_V_DEBT_WETH).balanceOf(account), 0, "short close: variableDebtWETH zero");
        assertEq(IERC20(EXPECTED_A_USDC).balanceOf(account), 0, "short close: aUSDC zero");
        assertEq(debt, 0, "short close: WETH debt fully repaid");
        assertEq(collateral, 0, "short close: all USDC collateral withdrawn");
        assertGt(residual, 0, "short close: residual USDC returned to owner");
        _assertNoDust(account);
    }

    // -------------------------------------------------------------------------
    // Setup + verification helpers
    // -------------------------------------------------------------------------

    /// @notice Deploys both adapters against their live protocols and verifies each resolved/registered
    ///         correctly: the Morpho market exists and matches the expected tokens; the Aave adapter
    ///         resolved the expected Pool, data provider, and reserve receipt tokens. Registers the
    ///         long on Morpho and the short on Aave, and sanity-checks each leg's max LTV.
    function _deployAndVerifyAdapters() internal {
        // long leg: live Morpho Blue WETH/USDC market (WETH collateral, USDC debt)
        morphoMarketParams =
            MarketParams({loanToken: USDC, collateralToken: WETH, oracle: MORPHO_ORACLE, irm: MORPHO_IRM, lltv: MORPHO_LLTV});
        assertEq(MORPHO.idToMarketParams(morphoMarketParams.id()).collateralToken, WETH, "morpho market collateral");
        assertEq(MORPHO.idToMarketParams(morphoMarketParams.id()).loanToken, USDC, "morpho market loan token");

        morphoAdapter = new MorphoLendingAdapter(MORPHO, address(this));
        morphoAdapter.setMarket(morphoMarketParams);
        assertTrue(morphoAdapter.isSupportedMarket(longMarket), "long market registered on Morpho adapter");
        assertEq(Ltv.unwrap(morphoAdapter.maxLtvWad(longMarket)), MORPHO_LLTV, "long: maxLtv == Morpho LLTV");

        // short leg: live Aave v3 (USDC collateral, WETH debt)
        aaveAdapter = new AaveLendingAdapter(AAVE_PROVIDER, address(this));
        assertEq(address(aaveAdapter.pool()), EXPECTED_AAVE_POOL, "resolved Aave Pool");
        assertEq(address(aaveAdapter.dataProvider()), EXPECTED_AAVE_DATA_PROVIDER, "resolved Aave data provider");

        (address aUsdc,,) = aaveAdapter.dataProvider().getReserveTokensAddresses(USDC);
        (,, address vWeth) = aaveAdapter.dataProvider().getReserveTokensAddresses(WETH);
        assertEq(aUsdc, EXPECTED_A_USDC, "aUSDC address");
        assertEq(vWeth, EXPECTED_V_DEBT_WETH, "variableDebtWETH address");

        aaveAdapter.setMarket(shortMarket.collateral, shortMarket.debt, true);
        assertTrue(aaveAdapter.isSupportedMarket(shortMarket), "short market registered on Aave adapter");
        assertGt(Ltv.unwrap(aaveAdapter.maxLtvWad(shortMarket)), 0, "short: Aave maxLtv positive");

        // sanity on baseline addresses both legs share
        assertGt(PERMIT2.code.length, 0, "permit2 deployed");
        assertGt(WETH.code.length, 0, "weth deployed");
        assertGt(USDC.code.length, 0, "usdc deployed");
    }

    /// @notice Reads the live Aave oracle prices for USDC and WETH (USD base, 8 decimals). These price
    ///         the v4 pool and size the short so its WETH debt matches the Morpho long's WETH collateral.
    function _readOraclePrices() internal {
        IAaveOracle oracle = IAaveOracle(AAVE_PROVIDER.getPriceOracle());
        usdcPriceBase = oracle.getAssetPrice(USDC);
        wethPriceBase = oracle.getAssetPrice(WETH);
        assertGt(usdcPriceBase, 0, "USDC oracle price positive");
        assertGt(wethPriceBase, 0, "WETH oracle price positive");
        console2.log("oracle USDC price (8d):", usdcPriceBase);
        console2.log("oracle WETH price (8d):", wethPriceBase);
    }

    /// @notice Initializes the USDC/WETH pool at the live Aave oracle price and seeds deep full-range
    ///         liquidity, so the swap leg values WETH the way the lenders do. The Morpho long buys WETH
    ///         (sells USDC) and the Aave short buys USDC (sells WETH) in this same pool, opposite
    ///         directions.
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

    /// @notice The USDC (6d) value of `wethAmount` (18d) WETH at the live oracle price. Used to size
    ///         the short's bought collateral to ~2 WETH-worth so its debt matches the long's collateral.
    function _usdcWorthOfWeth(uint256 wethAmount) internal view returns (uint128) {
        // USDC_raw = wethAmount(18d) * wethPriceBase / (usdcPriceBase * 1e12)
        uint256 usdc = FullMath.mulDiv(wethAmount, wethPriceBase, usdcPriceBase * 1e12);
        return uint128(usdc);
    }

    /// @notice A generous USDC `maxDebtIn` cap for the long buying `wethAmount` of WETH: the oracle
    ///         USDC cost plus a 10% slippage/fee buffer. Derived from a quote, not from spot price.
    function _maxUsdcForWeth(uint256 wethAmount) internal view returns (uint128) {
        return uint128(_usdcWorthOfWeth(wethAmount) * 110 / 100);
    }

    // -------------------------------------------------------------------------
    // Shared assertion + logging helpers
    // -------------------------------------------------------------------------

    /// @notice Asserts neither the account nor the router retains loose USDC or WETH.
    function _assertNoDust(address account) internal view {
        assertEq(IERC20(USDC).balanceOf(account), 0, "account holds no loose USDC");
        assertEq(IERC20(WETH).balanceOf(account), 0, "account holds no loose WETH");
        assertEq(IERC20(USDC).balanceOf(address(router)), 0, "router holds no loose USDC");
        assertEq(IERC20(WETH).balanceOf(address(router)), 0, "router holds no loose WETH");
    }

    /// @notice Logs the Morpho long leg's WETH collateral, USDC debt, and current LTV.
    function _logLong(string memory stage, address account) internal view {
        (uint256 collateral, uint256 debt) = morphoAdapter.positionOf(account, longMarket);
        console2.log(stage);
        console2.log("  collateral (WETH wei):", collateral);
        console2.log("  debt (USDC):", debt);
        console2.log("  ltv (WAD):", Ltv.unwrap(morphoAdapter.currentLtvWad(account, longMarket)));
    }

    /// @notice Logs the Aave short leg's USDC collateral, WETH debt, and current LTV.
    function _logShort(string memory stage, address account) internal view {
        (uint256 collateral, uint256 debt) = aaveAdapter.positionOf(account, shortMarket);
        console2.log(stage);
        console2.log("  collateral (USDC):", collateral);
        console2.log("  debt (WETH wei):", debt);
        console2.log("  ltv (WAD):", Ltv.unwrap(aaveAdapter.currentLtvWad(account, shortMarket)));
    }
}
