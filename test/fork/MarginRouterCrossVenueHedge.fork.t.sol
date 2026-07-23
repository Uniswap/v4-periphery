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
///         venues at once, through ONE MarginRouter, with the two legs isolated purely by subId.
///
///         Long leg  (subId 0): collateral WETH, debt USDC on live Morpho Blue -> long the WETH.
///         Short leg (subId 1): collateral USDC, debt WETH on live Aave v3   -> short the WETH.
///
///         Both legs are of matched ETH notional, so the long's +WETH collateral and the short's
///         -WETH debt net to ~zero ETH delta within swap slippage. This is the cross-venue
///         companion to the same-venue hedge: the long lives on Morpho, the short on Aave, and the
///         only thing the router uses to keep them apart is the subId, which it turns into two
///         distinct MarginAccount clones. Closing the Morpho long does not touch the Aave short and
///         vice versa, proving the two subId legs are isolated even across protocols.
///
///         The Morpho market, the Aave Pool, data provider, reserve receipt tokens, equity tokens
///         (WETH/USDC), Permit2, and WETH9 are all live mainnet contracts. Only the v4 pool is
///         local: one deep full-range WETH/USDC pool seeded at the live oracle price. The long buys
///         WETH selling USDC and the short buys USDC selling WETH in that same pool, opposite
///         directions. Direction is set purely by the market pairing; there is no Direction enum.
contract MarginRouterCrossVenueHedgeForkTest is Test {
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

    // snapshot of the Aave short leg, kept in storage so the cross-venue isolation check does not
    // pile locals onto one stack frame (tests compile without via_ir)
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

    /// @notice Proves one owner can run a LONG on Morpho (subId 0) and a SHORT on Aave (subId 1) of
    ///         matched ETH size through one router, that the pair is delta-neutral within swap
    ///         slippage, and that closing one venue's leg does not disturb the other's.
    function test_fork_crossVenueHedge_longMorpho_shortAave() public {
        address account0 = router.accountOf(owner, 0); // long, Morpho
        address account1 = router.accountOf(owner, 1); // short, Aave

        // opening deploys each subId's MarginAccount clone (they do not exist until first use)
        _openLongMorpho(account0);
        _openShortAave(account1);

        // (1) the two subIds resolve to distinct accounts, both owned by `owner`, both managed by router
        assertTrue(account0 != account1, "subId 0 and subId 1 yield distinct accounts");
        assertEq(MarginAccount(account0).owner(), owner, "long account owner is owner");
        assertEq(MarginAccount(account1).owner(), owner, "short account owner is owner");
        assertEq(MarginAccount(account0).manager(), address(router), "long account managed by router");
        assertEq(MarginAccount(account1).manager(), address(router), "short account managed by router");

        // (2) the Morpho long is the expected isolated position and is healthy on its own venue
        _assertLongHealthy(account0);
        // (3) the Aave short is the expected isolated position and is healthy on its own venue
        _assertShortHealthy(account1);

        // (4) the +WETH (Morpho long collateral) and -WETH (Aave short debt) match within slippage
        _assertDeltaNeutral(account0, account1);

        // (5) cross-venue isolation: closing the Morpho long leaves the Aave short untouched
        _snapshotShort(account1);
        _closeLongAndAssertUnwound(account0);
        _assertShortUnchanged(account1);

        // and the Aave short then closes cleanly on its own
        _closeShortAndAssertUnwound(account1);
    }

    // -------------------------------------------------------------------------
    // Per-leg open helpers (split to keep locals-per-frame low: tests compile without via_ir)
    // -------------------------------------------------------------------------

    /// @notice Opens the LONG on Morpho under subId 0: pre-fund 1 WETH equity, then buy +1 WETH funded
    ///         by USDC debt, landing ~2 WETH collateral against a USDC loan on the live Morpho market.
    function _openLongMorpho(address account0) internal {
        deal(WETH, account0, 1 ether);
        router.increasePosition(
            IMarginRouter.IncreaseParams({
                adapter: morphoAdapter,
                market: longMarket,
                poolKey: poolKey,
                equity: 0,
                collateralToBuy: LONG_BUY_WETH,
                maxDebtIn: _maxUsdcForWeth(LONG_BUY_WETH),
                minHopPriceX36: 0,
                maxLtvAfter: Ltv.wrap(0),
                subId: 0,
                deadline: block.timestamp + 1 hours
            })
        );
        _logLong("long open (Morpho, subId 0)", account0);
    }

    /// @notice Opens the SHORT on Aave under subId 1: size the bought USDC collateral to ~2 WETH-worth
    ///         so the resulting WETH debt matches the Morpho long's ~2 WETH collateral. Pre-fund an
    ///         equal USDC equity so total collateral is ~2x (healthy).
    function _openShortAave(address account1) internal {
        uint128 buyUsdc = _usdcWorthOfWeth(TARGET_WETH); // ~2 WETH worth of USDC collateral to buy
        deal(USDC, account1, buyUsdc); // equal USDC equity -> total collateral ~= 2 * buyUsdc
        router.increasePosition(
            IMarginRouter.IncreaseParams({
                adapter: aaveAdapter,
                market: shortMarket,
                poolKey: poolKey,
                equity: 0,
                collateralToBuy: buyUsdc,
                maxDebtIn: 2.2e18, // generous WETH cap (> ~2 WETH plus slippage/fees)
                minHopPriceX36: 0,
                maxLtvAfter: Ltv.wrap(0),
                subId: 1,
                deadline: block.timestamp + 1 hours
            })
        );
        _logShort("short open (Aave, subId 1)", account1);
    }

    // -------------------------------------------------------------------------
    // Per-leg assertion helpers
    // -------------------------------------------------------------------------

    /// @notice Asserts the Morpho long holds ~2 WETH collateral, a positive USDC debt, and is under
    ///         Morpho's max LTV (its LLTV).
    function _assertLongHealthy(address account0) internal view {
        (uint256 collateral, uint256 debt) = morphoAdapter.positionOf(account0, longMarket);
        assertApproxEqAbs(collateral, TARGET_WETH, 1, "long: collateral = equity + bought WETH");
        assertGt(debt, 0, "long: USDC debt drawn against live Morpho");

        uint256 ltv = Ltv.unwrap(morphoAdapter.currentLtvWad(account0, longMarket));
        assertGt(ltv, 0, "long: ltv positive");
        assertLt(ltv, Ltv.unwrap(morphoAdapter.maxLtvWad(longMarket)), "long: ltv under Morpho max");
        _assertNoDust(account0);
    }

    /// @notice Asserts the Aave short holds positive USDC collateral, a positive WETH debt, and is
    ///         under Aave's max LTV. Cross-checks the live aUSDC and variableDebtWETH receipt tokens.
    function _assertShortHealthy(address account1) internal view {
        (uint256 collateral, uint256 debt) = aaveAdapter.positionOf(account1, shortMarket);
        assertGt(collateral, 0, "short: USDC collateral supplied to real Aave");
        assertGt(debt, 0, "short: WETH debt borrowed from real Aave");
        assertApproxEqAbs(IERC20(EXPECTED_A_USDC).balanceOf(account1), collateral, 1, "short: aUSDC == collateral");
        assertEq(IERC20(EXPECTED_V_DEBT_WETH).balanceOf(account1), debt, "short: variableDebtWETH == debt");

        uint256 ltv = Ltv.unwrap(aaveAdapter.currentLtvWad(account1, shortMarket));
        assertGt(ltv, 0, "short: ltv positive");
        assertLt(ltv, Ltv.unwrap(aaveAdapter.maxLtvWad(shortMarket)), "short: ltv under Aave max");
        _assertNoDust(account1);
    }

    /// @notice The heart of the cross-venue hedge: the Morpho long's WETH collateral (+WETH) and the
    ///         Aave short's WETH debt (-WETH) match within ~2%, so the net ETH delta is near zero.
    ///         Logs the gross legs and the net so the hedge is visible, and bounds the net at < 5% of
    ///         the 2 WETH gross. The residual is pure swap slippage and fees; the position is
    ///         delta-neutral across the two venues within them.
    function _assertDeltaNeutral(address account0, address account1) internal view {
        (uint256 longWeth,) = morphoAdapter.positionOf(account0, longMarket);
        (, uint256 shortWeth) = aaveAdapter.positionOf(account1, shortMarket);

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
    // Cross-venue isolation helpers
    // -------------------------------------------------------------------------

    /// @notice Records the Aave short's (collateral, debt) before the Morpho long is closed, so the
    ///         close on the other venue can be proven not to disturb it.
    function _snapshotShort(address account1) internal {
        (_shortCollSnapshot, _shortDebtSnapshot) = aaveAdapter.positionOf(account1, shortMarket);
    }

    /// @notice Closes the Morpho LONG (subId 0), asserts the account is fully unwound (zero debt, zero
    ///         collateral) and that residual WETH was returned to the owner.
    function _closeLongAndAssertUnwound(address account0) internal {
        uint256 wethBefore = IERC20(WETH).balanceOf(owner);
        router.decreasePosition(
            IMarginRouter.DecreaseParams({
                debtToRepay: type(uint256).max,
                maxLtvAfter: Ltv.wrap(0),
                adapter: morphoAdapter,
                market: longMarket,
                poolKey: poolKey,
                maxCollateralIn: 3 ether,
                minHopPriceX36: 0,
                subId: 0,
                deadline: block.timestamp + 1 hours
            })
        );
        uint256 residual = IERC20(WETH).balanceOf(owner) - wethBefore;

        (uint256 collateral, uint256 debt) = morphoAdapter.positionOf(account0, longMarket);
        console2.log("long close (Morpho, subId 0) residual WETH:", residual);
        assertEq(debt, 0, "long close: USDC debt fully repaid");
        assertEq(collateral, 0, "long close: all WETH collateral withdrawn");
        assertGt(residual, 0, "long close: residual WETH returned to owner");
        _assertNoDust(account0);
    }

    /// @notice Asserts the Aave short is exactly as it was before the Morpho long was closed: the two
    ///         subId positions are isolated even across different venues.
    function _assertShortUnchanged(address account1) internal view {
        (uint256 collateral, uint256 debt) = aaveAdapter.positionOf(account1, shortMarket);
        assertEq(collateral, _shortCollSnapshot, "isolation: Aave short collateral untouched by Morpho close");
        assertEq(debt, _shortDebtSnapshot, "isolation: Aave short debt untouched by Morpho close");
        assertGt(debt, 0, "isolation: Aave short still open after Morpho close");
    }

    /// @notice Closes the Aave SHORT (subId 1), asserts the account is fully unwound (zero WETH debt,
    ///         zero USDC collateral, receipt tokens at zero) and that residual USDC went to the owner.
    function _closeShortAndAssertUnwound(address account1) internal {
        uint256 usdcBefore = IERC20(USDC).balanceOf(owner);
        router.decreasePosition(
            IMarginRouter.DecreaseParams({
                debtToRepay: type(uint256).max,
                maxLtvAfter: Ltv.wrap(0),
                adapter: aaveAdapter,
                market: shortMarket,
                poolKey: poolKey,
                maxCollateralIn: _usdcWorthOfWeth(3e18), // generous USDC cap (> ~2 WETH worth)
                minHopPriceX36: 0,
                subId: 1,
                deadline: block.timestamp + 1 hours
            })
        );
        uint256 residual = IERC20(USDC).balanceOf(owner) - usdcBefore;

        (uint256 collateral, uint256 debt) = aaveAdapter.positionOf(account1, shortMarket);
        console2.log("short close (Aave, subId 1) residual USDC:", residual);
        assertEq(IERC20(EXPECTED_V_DEBT_WETH).balanceOf(account1), 0, "short close: variableDebtWETH zero");
        assertEq(IERC20(EXPECTED_A_USDC).balanceOf(account1), 0, "short close: aUSDC zero");
        assertEq(debt, 0, "short close: WETH debt fully repaid");
        assertEq(collateral, 0, "short close: all USDC collateral withdrawn");
        assertGt(residual, 0, "short close: residual USDC returned to owner");
        _assertNoDust(account1);
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
        morphoMarketParams = MarketParams({
            loanToken: USDC, collateralToken: WETH, oracle: MORPHO_ORACLE, irm: MORPHO_IRM, lltv: MORPHO_LLTV
        });
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
