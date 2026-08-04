// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/console2.sol";
import "forge-std/Script.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";

import {IOracle} from "morpho-blue/interfaces/IOracle.sol";

import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";

import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";

import {IV4Quoter} from "../src/interfaces/IV4Quoter.sol";
import {V4Quoter} from "../src/lens/V4Quoter.sol";
import {IMarginRouter} from "../src/interfaces/IMarginRouter.sol";
import {MorphoLendingAdapter} from "../src/MorphoLendingAdapter.sol";
import {Market} from "../src/types/Market.sol";
import {Ltv, raw} from "../src/types/Ltv.sol";
import {IV4Router} from "../src/interfaces/IV4Router.sol";
import {Actions} from "../src/libraries/Actions.sol";
import {ActionConstants} from "../src/libraries/ActionConstants.sol";
import {Commands} from "universal-router/contracts/libraries/Commands.sol";

/// @title OpenMorphoLongEth
/// @notice Opens a long ETH margin position (WETH collateral, USDC debt) on the deployed Morpho
///         adapter at a target gross leverage (default ~5x), using the sender's WETH as equity,
///         pulled through Permit2.
/// @dev Broadcast example (mainnet):
///      forge script script/OpenMorphoLongEth.s.sol:OpenMorphoLongEth --rpc-url $MAINNET_RPC_URL
///        --broadcast --slow --sender 0x1199A3f7bEf0211db99d843e330f32400548c8AE --private-key $TRADER_PRIVATE_KEY
///      Optional env overrides:
///        MARGIN_ROUTER, MORPHO_ADAPTER, POOL_FEE, POOL_TICK_SPACING, POOL_HOOKS,
///        EQUITY_WEI (default 0: use the sender's full WETH balance),
///        GAS_RESERVE_WEI (default 0.01 ether, ETH the sender must hold for gas), SUB_ID,
///        LEVERAGE_X10 (default 50 = 5.0x gross leverage; sets the target LTV),
///        SLIPPAGE_BPS (default 100), V4_QUOTER (optional; ephemeral quoter deployed if unset),
///        LTV_BUFFER_BPS (default 50, caps the target LTV slightly under the market max),
///        DEADLINE_SECONDS (default 1800).
contract OpenMorphoLongEth is Script {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using SafeERC20 for IERC20;

    /// @dev Deployed mainnet margin suite (DeployMargin.s.sol broadcast, chain 1).
    address internal constant DEFAULT_MARGIN_ROUTER = 0x000000a16bfA211d163C244427acE70dD9014444;
    address internal constant DEFAULT_MORPHO_ADAPTER = 0xAc150756CAa1e7b821AE2ef4b6f66030A715d474;
    address internal constant DEFAULT_POOL_MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;

    address internal constant MAINNET_WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address internal constant MAINNET_USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    // Oracle of the canonical Morpho WETH/USDC market
    // (id 0x94b823e6bd8ea533b4e33fbc307faea0b307301bc48763acc4d4aa4def7636cd).
    address internal constant MAINNET_MORPHO_WETH_USDC_ORACLE = 0x0F948CBa8231Db7898ef36A4212581Ad7b1B4580;

    uint256 internal constant WAD = 1e18;
    uint256 internal constant ORACLE_PRICE_SCALE = 1e36;
    uint256 internal constant BPS = 10_000;

    function run() external {
        IMarginRouter router = IMarginRouter(_envAddress("MARGIN_ROUTER", DEFAULT_MARGIN_ROUTER));
        MorphoLendingAdapter adapter = MorphoLendingAdapter(_envAddress("MORPHO_ADAPTER", DEFAULT_MORPHO_ADAPTER));

        require(
            address(router.poolManager()) == _envAddress("POOL_MANAGER", DEFAULT_POOL_MANAGER), "pool manager mismatch"
        );
        require(router.isAdapterAllowed(adapter), "Morpho adapter not allowlisted");

        Market memory market = Market({collateral: Currency.wrap(MAINNET_WETH), debt: Currency.wrap(MAINNET_USDC)});
        require(adapter.isSupportedMarket(market), "Morpho long ETH market not registered");

        PoolKey memory poolKey = _poolKey();
        _requireInitializedPool(router.poolManager(), poolKey);

        uint256 subId = vm.envOr("SUB_ID", uint256(0));
        uint256 slippageBps = vm.envOr("SLIPPAGE_BPS", uint256(100));
        uint256 ltvBufferBps = vm.envOr("LTV_BUFFER_BPS", uint256(50));
        uint256 leverageX10 = vm.envOr("LEVERAGE_X10", uint256(50));
        uint256 deadline = block.timestamp + vm.envOr("DEADLINE_SECONDS", uint256(30 minutes));

        IERC20 weth = IERC20(MAINNET_WETH);
        uint256 equity = vm.envOr("EQUITY_WEI", uint256(0));
        if (equity == 0) equity = weth.balanceOf(msg.sender);
        require(equity > 0, "no WETH equity: fund the trader with WETH or set EQUITY_WEI");

        Ltv maxLtv = adapter.maxLtvWad(market);
        IV4Quoter quoter = _quoter(router.poolManager());
        bool zeroForOne = market.debt == poolKey.currency0;

        uint256 maxLtvWad = raw(maxLtv);
        require(leverageX10 > 10, "LEVERAGE_X10 must exceed 10 (1.0x)");
        // gross leverage L implies LTV (L - 1) / L: at 5.0x the debt is 4/5 of collateral value
        uint256 targetLtvWad = (leverageX10 - 10) * WAD / leverageX10;
        require(
            targetLtvWad <= maxLtvWad * (BPS - ltvBufferBps) / BPS,
            "LEVERAGE_X10 puts target LTV above the market max minus LTV_BUFFER_BPS"
        );
        uint256 oraclePrice = IOracle(MAINNET_MORPHO_WETH_USDC_ORACLE).price();

        uint128 collateralToBuy =
            _collateralToBuyAtTargetLtv(quoter, poolKey, zeroForOne, equity, targetLtvWad, oraclePrice);
        (uint128 maxDebtIn, uint256 quotedDebtIn) =
            _maxDebtInFromPoolQuote(quoter, poolKey, zeroForOne, collateralToBuy, slippageBps);

        address account = router.accountOf(msg.sender, subId);
        uint256 gasReserve = vm.envOr("GAS_RESERVE_WEI", uint256(0.01 ether));
        uint256 wethBalance = weth.balanceOf(msg.sender);

        _logPlan(
            router,
            adapter,
            account,
            poolKey,
            equity,
            collateralToBuy,
            quotedDebtIn,
            maxDebtIn,
            maxLtvWad,
            targetLtvWad,
            slippageBps,
            oraclePrice,
            wethBalance,
            gasReserve,
            subId,
            deadline
        );

        require(wethBalance >= equity, "insufficient WETH: fund trader or lower EQUITY_WEI");
        require(msg.sender.balance >= gasReserve, "insufficient ETH for gas (balance < GAS_RESERVE_WEI)");

        IAllowanceTransfer permit2 = router.permit2();

        vm.startBroadcast(msg.sender);

        // WETH equity is pulled through Permit2: the token must approve Permit2, and Permit2 must
        // have a (token, router) allowance for the sender; top up whichever is short
        if (weth.allowance(msg.sender, address(permit2)) < equity) {
            weth.forceApprove(address(permit2), equity);
        }
        (uint160 permitAmount, uint48 permitExpiration,) = permit2.allowance(msg.sender, MAINNET_WETH, address(router));
        // forge-lint: disable-next-line(block-timestamp)
        if (permitAmount < equity || permitExpiration <= block.timestamp) {
            // casts are safe: equity is a WETH balance (far below 2^160) and deadline is
            // block.timestamp plus at most hours (far below 2^48)
            // forge-lint: disable-next-line(unsafe-typecast)
            permit2.approve(MAINNET_WETH, address(router), uint160(equity), uint48(deadline));
        }

        // the Universal Router is now supplied per call rather than baked into the router, so the
        // operator points this open at the UR the route targets (must carry already-unlocked V4_SWAP)
        address universalRouter = _envAddress("UNIVERSAL_ROUTER", address(0));
        require(universalRouter != address(0), "set UNIVERSAL_ROUTER env to the Universal Router");

        // build the Universal Router route the curated open now takes: a single-pool v4 exact-output
        // swap over `poolKey` that buys `collateralToBuy` WETH for the USDC the router flash-takes,
        // pulling the USDC from the router (payer) via Permit2 and delivering the WETH to the account
        (bytes memory routeCommands, bytes[] memory routeInputs) =
            _v4Route(poolKey, market.debt, market.collateral, uint128(collateralToBuy), uint128(maxDebtIn), account);

        router.increasePosition(
            IMarginRouter.IncreaseParams({
                adapter: adapter,
                market: market,
                equity: equity,
                collateralToBuy: uint128(collateralToBuy),
                maxDebtIn: uint128(maxDebtIn),
                universalRouter: universalRouter,
                routeCommands: routeCommands,
                routeInputs: routeInputs,
                maxLtvAfter: Ltv.wrap(0),
                subId: subId,
                deadline: deadline
            })
        );

        vm.stopBroadcast();

        (uint256 collateral, uint256 debt) = adapter.positionOf(account, market);
        Ltv currentLtv = adapter.currentLtvWad(account, market);

        _logResult(collateral, debt, raw(currentLtv), equity, collateralToBuy, oraclePrice);
        require(raw(currentLtv) < maxLtvWad, "position at or above market max LTV");
        require(collateral >= equity + collateralToBuy, "collateral below equity + buy");
    }

    /// @notice Finds the largest `collateralToBuy` whose Morpho LTV (oracle-valued collateral,
    ///         pool-quoted debt) stays at or under the target LTV.
    function _collateralToBuyAtTargetLtv(
        IV4Quoter quoter,
        PoolKey memory poolKey,
        bool zeroForOne,
        uint256 equity,
        uint256 targetLtvWad,
        uint256 oraclePrice
    ) internal returns (uint128 collateralToBuy) {
        require(targetLtvWad > 0 && targetLtvWad < WAD, "invalid target LTV");

        // Ratio-form upper bound; valid buy size is never above this.
        uint256 high = FullMath.mulDiv(equity, targetLtvWad, WAD - targetLtvWad);
        require(high <= type(uint128).max, "collateralToBuy overflow");
        require(high > 0, "collateralToBuy zero bound");

        uint256 low = 0;
        for (uint256 i = 0; i < 64; ++i) {
            uint256 mid = (low + high + 1) >> 1;
            uint256 debtIn = _quoteDebtIn(quoter, poolKey, zeroForOne, mid);
            uint256 collateralValue = FullMath.mulDiv(equity + mid, oraclePrice, ORACLE_PRICE_SCALE);
            uint256 ltvWad = debtIn * WAD / collateralValue;
            if (ltvWad <= targetLtvWad) {
                low = mid;
            } else {
                high = mid - 1;
            }
        }

        require(low > 0, "no leverage size fits the target LTV at pool/oracle prices");
        collateralToBuy = uint128(low);
    }

    function _quoteDebtIn(IV4Quoter quoter, PoolKey memory poolKey, bool zeroForOne, uint256 collateralToBuy)
        internal
        returns (uint256 debtIn)
    {
        require(collateralToBuy <= type(uint128).max, "quote amount overflow");
        (debtIn,) = quoter.quoteExactOutputSingle(
            IV4Quoter.QuoteExactSingleParams({
                poolKey: poolKey, zeroForOne: zeroForOne, exactAmount: uint128(collateralToBuy), hookData: ""
            })
        );
    }

    /// @notice Quotes the v4 exact-output swap (sell USDC, buy WETH) and applies a slippage buffer.
    /// @dev Uses `V4_QUOTER` when set; otherwise deploys an ephemeral quoter (simulation only, not
    ///      broadcast). Do not size from the Morpho oracle — pool and oracle prices can diverge
    ///      enough to trip `V4TooMuchRequested`.
    function _maxDebtInFromPoolQuote(
        IV4Quoter quoter,
        PoolKey memory poolKey,
        bool zeroForOne,
        uint128 collateralToBuy,
        uint256 slippageBps
    ) internal returns (uint128 maxDebtIn, uint256 quotedDebtIn) {
        quotedDebtIn = _quoteDebtIn(quoter, poolKey, zeroForOne, collateralToBuy);

        uint256 capped = quotedDebtIn * (BPS + slippageBps) / BPS;
        require(capped <= type(uint128).max, "maxDebtIn overflow");
        require(capped > 0, "maxDebtIn zero");
        maxDebtIn = uint128(capped);
    }

    function _quoter(IPoolManager poolManager) internal returns (IV4Quoter quoter) {
        address configured = _envAddress("V4_QUOTER", address(0));
        if (configured != address(0)) {
            require(configured.code.length > 0, "V4_QUOTER has no code");
            return IV4Quoter(configured);
        }
        return IV4Quoter(address(new V4Quoter(poolManager)));
    }

    /// @dev Builds a single-pool v4 exact-output Universal Router route: buy `amountOut` of `output`
    ///      for at most `maxIn` of `input` over `poolKey`, pulling the input from the router (the UR
    ///      caller/payer) via Permit2 and delivering the output to `recipient`.
    function _v4Route(
        PoolKey memory poolKey,
        Currency input,
        Currency output,
        uint128 amountOut,
        uint128 maxIn,
        address recipient
    ) internal pure returns (bytes memory commands, bytes[] memory inputs) {
        bytes memory v4Actions = abi.encodePacked(
            uint8(Actions.SWAP_EXACT_OUT_SINGLE), uint8(Actions.SETTLE), uint8(Actions.TAKE)
        );
        bytes[] memory v4Params = new bytes[](3);
        v4Params[0] = abi.encode(
            IV4Router.ExactOutputSingleParams({
                poolKey: poolKey,
                zeroForOne: Currency.unwrap(input) == Currency.unwrap(poolKey.currency0),
                amountOut: amountOut,
                amountInMaximum: maxIn,
                minHopPriceX36: 0,
                hookData: ""
            })
        );
        v4Params[1] = abi.encode(input, uint256(ActionConstants.OPEN_DELTA), true);
        v4Params[2] = abi.encode(output, recipient, uint256(ActionConstants.OPEN_DELTA));
        inputs = new bytes[](1);
        inputs[0] = abi.encode(v4Actions, v4Params);
        commands = abi.encodePacked(uint8(Commands.V4_SWAP));
    }

    function _poolKey() internal view returns (PoolKey memory poolKey) {
        require(MAINNET_USDC < MAINNET_WETH, "currency ordering");
        poolKey = PoolKey({
            currency0: Currency.wrap(MAINNET_USDC),
            currency1: Currency.wrap(MAINNET_WETH),
            fee: uint24(vm.envOr("POOL_FEE", uint256(500))),
            tickSpacing: int24(int256(vm.envOr("POOL_TICK_SPACING", int256(10)))),
            hooks: IHooks(_envAddress("POOL_HOOKS", address(0)))
        });
    }

    function _requireInitializedPool(IPoolManager manager, PoolKey memory poolKey) internal view {
        PoolId poolId = poolKey.toId();
        (uint160 sqrtPriceX96,,,) = manager.getSlot0(poolId);
        require(sqrtPriceX96 != 0, "v4 pool not initialized; set POOL_FEE/POOL_TICK_SPACING/POOL_HOOKS");
    }

    function _envAddress(string memory key, address defaultValue) internal view returns (address value) {
        try vm.envAddress(key) returns (address configured) {
            return configured;
        } catch {
            return defaultValue;
        }
    }

    function _logPlan(
        IMarginRouter router,
        MorphoLendingAdapter adapter,
        address account,
        PoolKey memory poolKey,
        uint256 equity,
        uint128 collateralToBuy,
        uint256 quotedDebtIn,
        uint128 maxDebtIn,
        uint256 maxLtvWad,
        uint256 targetLtvWad,
        uint256 slippageBps,
        uint256 oraclePrice,
        uint256 wethBalance,
        uint256 gasReserve,
        uint256 subId,
        uint256 deadline
    ) internal view {
        uint256 totalCollateral = equity + collateralToBuy;
        uint256 oracleEthUsd = _usdcPerEthFromOracle(oraclePrice);
        uint256 quoteEthUsd = _usdcPerEthFromTrade(quotedDebtIn, collateralToBuy);

        _logSection("Open Morpho long ETH (WETH collateral / USDC debt)");
        console2.log("trader", msg.sender);
        console2.log("sub-account id", subId);
        console2.log("margin account", account);
        console2.log("margin router", address(router));
        console2.log("morpho adapter", address(adapter));
        console2.log("deadline (unix)", deadline);

        _logSection("Wallet");
        console2.log("WETH balance", _fmtEth(wethBalance));
        console2.log("equity deposit (WETH)", _fmtEth(equity));
        console2.log("ETH balance (gas)", _fmtEth(msg.sender.balance));
        console2.log("gas reserve", _fmtEth(gasReserve));

        _logSection("v4 swap pool (USDC / WETH)");
        console2.log("pool id", vm.toString(PoolId.unwrap(poolKey.toId())));
        console2.log("fee tier", _fmtFeeTier(poolKey.fee));
        console2.log("tick spacing", poolKey.tickSpacing);
        console2.log("hooks", address(poolKey.hooks));

        _logSection("Position sizing");
        console2.log("equity", _fmtEth(equity));
        console2.log("+ WETH bought on v4", _fmtEth(collateralToBuy));
        console2.log("= total WETH collateral", _fmtEth(totalCollateral));
        console2.log("gross leverage", _fmtLeverage(equity, totalCollateral));
        console2.log("USDC debt (quoted)", _fmtUsdc(quotedDebtIn));
        console2.log("USDC maxDebtIn", _fmtUsdc(maxDebtIn), _fmtBpsSuffix(slippageBps));

        _logSection("LTV limits (Morpho oracle)");
        console2.log("market max LTV", _fmtPct(maxLtvWad));
        console2.log("target LTV", _fmtPct(targetLtvWad), "(from LEVERAGE_X10)");

        _logSection("ETH / USD prices");
        console2.log("morpho oracle", _fmtUsd(oracleEthUsd), "/ ETH");
        console2.log("v4 quote (this trade)", _fmtUsd(quoteEthUsd), "/ ETH");
        if (quoteEthUsd > 0) {
            console2.log("oracle / quote", _fmtRatioBps(oracleEthUsd, quoteEthUsd));
        }
    }

    function _logResult(
        uint256 collateral,
        uint256 debt,
        uint256 currentLtvWad,
        uint256 equity,
        uint128 collateralToBuy,
        uint256 oraclePrice
    ) internal view {
        uint256 collateralValue = FullMath.mulDiv(collateral, oraclePrice, ORACLE_PRICE_SCALE);

        _logSection("Opened position");
        console2.log("WETH collateral", _fmtEth(collateral));
        console2.log("USDC debt", _fmtUsdc(debt));
        console2.log("gross leverage", _fmtLeverage(equity, collateral));
        console2.log("Morpho LTV", _fmtPct(currentLtvWad));
        console2.log("collateral value (oracle)", _fmtUsdc(collateralValue));
        console2.log("expected WETH", _fmtEth(equity + collateralToBuy), "(equity + buy)");
    }

    function _logSection(string memory title) internal view {
        console2.log(string.concat("--- ", title, " ---"));
    }

    function _usdcPerEthFromOracle(uint256 oraclePrice) internal pure returns (uint256) {
        return oraclePrice * 1e18 / ORACLE_PRICE_SCALE / 1e6;
    }

    function _usdcPerEthFromTrade(uint256 usdcAmount, uint256 ethWei) internal pure returns (uint256) {
        if (ethWei == 0) return 0;
        return usdcAmount * 1e18 / ethWei / 1e6;
    }

    function _fmtEth(uint256 weiAmount) internal pure returns (string memory) {
        uint256 whole = weiAmount / 1e18;
        uint256 frac4 = (weiAmount % 1e18) / 1e14;
        return string.concat(vm.toString(whole), ".", _zeroPad4(frac4), " ETH");
    }

    function _fmtUsdc(uint256 amount) internal pure returns (string memory) {
        uint256 dollars = amount / 1e6;
        uint256 cents = (amount % 1e6) / 1e4;
        return string.concat("$", vm.toString(dollars), ".", _zeroPad2(cents));
    }

    function _fmtUsd(uint256 dollars) internal pure returns (string memory) {
        return string.concat("$", vm.toString(dollars));
    }

    function _fmtPct(uint256 wad) internal pure returns (string memory) {
        uint256 pctTimes100 = wad * 10_000 / WAD;
        uint256 whole = pctTimes100 / 100;
        uint256 frac = pctTimes100 % 100;
        return string.concat(vm.toString(whole), ".", _zeroPad2(frac), "%");
    }

    function _fmtLeverage(uint256 equity, uint256 totalCollateral) internal pure returns (string memory) {
        if (equity == 0) return "n/a";
        uint256 leverageTenths = totalCollateral * 10 / equity;
        uint256 whole = leverageTenths / 10;
        uint256 frac = leverageTenths % 10;
        return string.concat(vm.toString(whole), ".", vm.toString(frac), "x");
    }

    function _fmtFeeTier(uint24 fee) internal pure returns (string memory) {
        uint256 hundredths = fee / 100;
        uint256 whole = hundredths / 100;
        uint256 frac = hundredths % 100;
        if (whole > 0) {
            return string.concat(vm.toString(whole), ".", _zeroPad2(frac), "%");
        }
        return string.concat("0.", _zeroPad2(frac), "%");
    }

    function _fmtBpsSuffix(uint256 bps) internal pure returns (string memory) {
        return string.concat("(includes ", vm.toString(bps), " bps slippage buffer)");
    }

    function _fmtRatioBps(uint256 numerator, uint256 denominator) internal pure returns (string memory) {
        if (denominator == 0) return "n/a";
        uint256 bps = numerator * BPS / denominator;
        uint256 whole = bps / 100;
        uint256 frac = bps % 100;
        return string.concat(vm.toString(whole), ".", _zeroPad2(frac), "%");
    }

    function _zeroPad2(uint256 n) internal pure returns (string memory) {
        if (n >= 10) return vm.toString(n);
        return string.concat("0", vm.toString(n));
    }

    function _zeroPad4(uint256 n) internal pure returns (string memory) {
        if (n >= 1000) return vm.toString(n);
        if (n >= 100) return string.concat("0", vm.toString(n));
        if (n >= 10) return string.concat("00", vm.toString(n));
        return string.concat("000", vm.toString(n));
    }
}
