// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/console2.sol";
import "forge-std/Script.sol";

import {IMorpho, IMorphoBase, MarketParams, Id, Position} from "morpho-blue/interfaces/IMorpho.sol";
import {MarketParamsLib} from "morpho-blue/libraries/MarketParamsLib.sol";

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {MorphoLendingAdapter} from "../src/MorphoLendingAdapter.sol";
import {Market} from "../src/types/Market.sol";
import {Ltv, raw} from "../src/types/Ltv.sol";

/// @title FixMorphoWethUsdcMarket
/// @notice Re-points the deployed Morpho adapter's WETH/USDC (long ETH) route at the canonical
///         mainnet Morpho Blue market. The original deployment registered a market that differs
///         from the canonical one only in its oracle, which hashes to an unlisted, near-empty
///         market id. Because the adapter's registry keys one market per (collateral, debt) pair,
///         registering the canonical params replaces the stale entry in the same call; no separate
///         deregistration exists or is needed.
/// @dev Broadcast example (mainnet, sender must be the adapter owner):
///      forge script script/FixMorphoWethUsdcMarket.s.sol:FixMorphoWethUsdcMarket
///        --rpc-url $MAINNET_RPC_URL --sender <adapter owner> --private-key $OWNER_PRIVATE_KEY
///        --broadcast --slow
///      Run without --broadcast first to dry-run the simulation and verification asserts.
///      Optional env overrides:
///        MORPHO_ADAPTER (default: mainnet deployment),
///        STALE_MARKET_ACCOUNT (optional; if set, warns when that account still holds collateral
///        or debt in the stale market, which the adapter can no longer route to after this fix).
contract FixMorphoWethUsdcMarket is Script {
    using MarketParamsLib for MarketParams;

    /// @dev Deployed mainnet Morpho adapter (DeployMargin.s.sol broadcast, chain 1).
    address internal constant DEFAULT_MORPHO_ADAPTER = 0xAc150756CAa1e7b821AE2ef4b6f66030A715d474;

    address internal constant MAINNET_WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address internal constant MAINNET_USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

    // Canonical mainnet Morpho WETH/USDC market, read back from morpho.idToMarketParams(id):
    // loan USDC, collateral WETH, adaptive curve IRM, 86% LLTV.
    bytes32 internal constant CANONICAL_MARKET_ID = 0x94b823e6bd8ea533b4e33fbc307faea0b307301bc48763acc4d4aa4def7636cd;
    address internal constant CANONICAL_ORACLE = 0x0F948CBa8231Db7898ef36A4212581Ad7b1B4580;
    address internal constant MORPHO_IRM = 0x870aC11D48B15DB9a138Cf899d20F13F79Ba00BC;
    uint256 internal constant MORPHO_LLTV = 0.86e18;

    // The stale market the deployment registered: identical params except oracle 0xdC6fd583...,
    // hashing to an unlisted market id with negligible liquidity.
    bytes32 internal constant STALE_MARKET_ID = 0x7dde86a1e94561d9690ec678db673c1a6396365f7d1d65e129c5fff0990ff758;

    // Arbitrary account used only to compare encoded calldata; never called or funded.
    address internal constant PROBE_ACCOUNT = address(1);

    function run() external {
        MorphoLendingAdapter adapter = MorphoLendingAdapter(vm.envOr("MORPHO_ADAPTER", DEFAULT_MORPHO_ADAPTER));
        IMorpho morpho = adapter.morpho();

        MarketParams memory canonical = MarketParams({
            loanToken: MAINNET_USDC,
            collateralToken: MAINNET_WETH,
            oracle: CANONICAL_ORACLE,
            irm: MORPHO_IRM,
            lltv: MORPHO_LLTV
        });
        require(Id.unwrap(canonical.id()) == CANONICAL_MARKET_ID, "canonical params do not hash to expected id");

        // the canonical market must exist on Morpho Blue with the exact tokens we expect
        MarketParams memory onchain = morpho.idToMarketParams(Id.wrap(CANONICAL_MARKET_ID));
        require(onchain.loanToken == MAINNET_USDC, "canonical market missing or wrong loan token");
        require(onchain.collateralToken == MAINNET_WETH, "canonical market has wrong collateral token");

        Market memory market = Market({collateral: Currency.wrap(MAINNET_WETH), debt: Currency.wrap(MAINNET_USDC)});
        if (adapter.isSupportedMarket(market) && _routesTo(adapter, market, canonical)) {
            console2.log("Adapter already routes WETH/USDC to the canonical market; nothing to do");
            return;
        }

        require(adapter.owner() == msg.sender, "sender is not the adapter owner");

        _warnOnStalePosition(morpho);

        vm.startBroadcast();
        // registering the canonical params overwrites the stale entry for the same
        // (collateral, debt) key, deregistering the unlisted market in the same call
        adapter.setMarket(canonical);
        vm.stopBroadcast();

        require(adapter.isSupportedMarket(market), "WETH/USDC market not registered after fix");
        require(_routesTo(adapter, market, canonical), "adapter does not route to the canonical market after fix");
        require(raw(adapter.maxLtvWad(market)) == MORPHO_LLTV, "unexpected max LTV after fix");

        console2.log("MorphoLendingAdapter", address(adapter));
        console2.log("WETH/USDC route replaced. Canonical market id:");
        console2.logBytes32(CANONICAL_MARKET_ID);
        console2.log("Stale market id no longer routed:");
        console2.logBytes32(STALE_MARKET_ID);
    }

    /// @notice True if the adapter currently resolves `market` to exactly `params`.
    /// @dev The registry is internal, so the routed params are recovered from the calldata the
    ///      adapter encodes: a zero-amount supplyCollateral embeds the full MarketParams, which is
    ///      compared byte-for-byte against the expected encoding.
    function _routesTo(MorphoLendingAdapter adapter, Market memory market, MarketParams memory params)
        internal
        view
        returns (bool)
    {
        (,, bytes memory data) = adapter.encodeSupplyCollateral(PROBE_ACCOUNT, market, 0);
        bytes memory expected = abi.encodeCall(IMorphoBase.supplyCollateral, (params, 0, PROBE_ACCOUNT, ""));
        return keccak256(data) == keccak256(expected);
    }

    /// @notice Warns when STALE_MARKET_ACCOUNT still has collateral or debt in the stale market.
    ///         After the fix the adapter can no longer encode repay/withdraw calls for it, so any
    ///         residue there must be unwound before broadcasting.
    function _warnOnStalePosition(IMorpho morpho) internal view {
        address account = vm.envOr("STALE_MARKET_ACCOUNT", address(0));
        if (account == address(0)) return;
        Position memory position = morpho.position(Id.wrap(STALE_MARKET_ID), account);
        if (position.collateral == 0 && position.borrowShares == 0) {
            console2.log("Stale market position for", account, "is empty; safe to proceed");
            return;
        }
        console2.log("WARNING: residual position in the stale market for", account);
        console2.log("  collateral (wei)", uint256(position.collateral));
        console2.log("  borrow shares", uint256(position.borrowShares));
        console2.log("  unwind it before broadcasting; the adapter cannot route to it after the fix");
    }
}
