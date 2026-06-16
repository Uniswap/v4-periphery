// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/console2.sol";
import "forge-std/Script.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IMorpho, MarketParams} from "morpho-blue/interfaces/IMorpho.sol";

import {IWETH9} from "../src/interfaces/external/IWETH9.sol";
import {IPoolAddressesProvider} from "../src/interfaces/external/aave/IPoolAddressesProvider.sol";

import {MarginRouter} from "../src/MarginRouter.sol";
import {MarginAccount} from "../src/MarginAccount.sol";
import {MorphoLendingAdapter} from "../src/MorphoLendingAdapter.sol";
import {AaveLendingAdapter} from "../src/AaveLendingAdapter.sol";

/// @title DeployMargin
/// @notice Deploys the margin-trading suite: the deterministic MarginAccount implementation, the
///         Morpho and Aave lending adapters, and the MarginRouter at a mined vanity salt. Wires the
///         adapter allowlist and, on mainnet, registers the canonical markets.
/// @dev    Deployment notes:
///         - The broadcaster MUST equal `governance`. The adapters are constructed with `governance`
///           as their owner and the router with `governance` as its governance, and this script then
///           calls `setAdapterAllowed` (router governance) and `setMarket` (adapter owner) inline.
///           Those calls revert unless the broadcasting key is `governance`. After setup, governance
///           can hand off each role via the two-step transferGovernance/acceptGovernance (router) and
///           transferOwnership/acceptOwnership (adapters).
///         - `routerSalt` comes from MineMarginRouterSalt and is only valid for the exact
///           (poolManager, permit2, weth9, accountImpl, governance) tuple it was mined against. The
///           accountImpl is itself derived from ACCOUNT_SALT, so ACCOUNT_SALT here MUST match the
///           miner; otherwise the mined router address will not be produced.
contract DeployMargin is Script {
    /// @dev Salt for the deterministic MarginAccount implementation. Must match MineMarginRouterSalt.
    bytes32 internal constant ACCOUNT_SALT = keccak256("uniswap.margin.MarginAccount.v1");

    /// @dev Fixed salts for the adapters. Their addresses need not be vanity, only deterministic.
    bytes32 internal constant MORPHO_ADAPTER_SALT = keccak256("uniswap.margin.MorphoLendingAdapter.v1");
    bytes32 internal constant AAVE_ADAPTER_SALT = keccak256("uniswap.margin.AaveLendingAdapter.v1");

    // Verified mainnet token addresses, used only for the chainid == 1 market registration.
    address internal constant MAINNET_WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address internal constant MAINNET_USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    // Morpho WETH/USDC market (long ETH): collateral WETH, loan USDC.
    address internal constant MAINNET_MORPHO_WETH_USDC_ORACLE = 0xdC6fd5831277c693b1054e19E94047cB37c77615;
    address internal constant MAINNET_MORPHO_WETH_USDC_IRM = 0x870aC11D48B15DB9a138Cf899d20F13F79Ba00BC;
    uint256 internal constant MAINNET_MORPHO_WETH_USDC_LLTV = 0.86e18;

    function setUp() public {}

    /// @notice Deploys and wires the margin suite.
    /// @param poolManager The v4 PoolManager singleton the router unlocks for every position flow.
    /// @param permit2 The Permit2 contract used to pull caller equity and settle swaps.
    /// @param weth9 The canonical WETH9 used to wrap native ETH equity.
    /// @param governance The initial governance/owner of the router and adapters. MUST equal the
    ///        broadcaster so the inline allowlist and market wiring succeed.
    /// @param morpho The Morpho Blue singleton the Morpho adapter routes through.
    /// @param aaveProvider The Aave v3 PoolAddressesProvider the Aave adapter resolves its Pool from.
    /// @param routerSalt The vanity salt from MineMarginRouterSalt, valid only for the exact
    ///        (poolManager, permit2, weth9, accountImpl, governance) tuple it was mined against.
    /// @return impl The deployed MarginAccount implementation.
    /// @return morphoAdapter The deployed Morpho lending adapter.
    /// @return aaveAdapter The deployed Aave lending adapter.
    /// @return router The deployed MarginRouter.
    function run(
        address poolManager,
        address permit2,
        address weth9,
        address governance,
        address morpho,
        address aaveProvider,
        bytes32 routerSalt
    )
        public
        returns (
            MarginAccount impl,
            MorphoLendingAdapter morphoAdapter,
            AaveLendingAdapter aaveAdapter,
            MarginRouter router
        )
    {
        vm.startBroadcast();

        // deterministic account implementation; its address must match the miner's derivation so the
        // router lands at the mined vanity salt
        impl = new MarginAccount{salt: ACCOUNT_SALT}();
        console2.log("MarginAccount implementation", address(impl));

        // adapters owned by governance
        morphoAdapter = new MorphoLendingAdapter{salt: MORPHO_ADAPTER_SALT}(IMorpho(morpho), governance);
        console2.log("MorphoLendingAdapter", address(morphoAdapter));

        aaveAdapter = new AaveLendingAdapter{salt: AAVE_ADAPTER_SALT}(IPoolAddressesProvider(aaveProvider), governance);
        console2.log("AaveLendingAdapter", address(aaveAdapter));

        // router at the mined vanity salt
        router = new MarginRouter{salt: routerSalt}(
            IPoolManager(poolManager), IAllowanceTransfer(permit2), IWETH9(weth9), address(impl), governance
        );
        console2.log("MarginRouter", address(router));

        // wire the allowlist; requires the broadcaster to be governance
        router.setAdapterAllowed(morphoAdapter, true);
        router.setAdapterAllowed(aaveAdapter, true);

        if (block.chainid == 1) {
            // long ETH on Morpho: collateral WETH, debt USDC
            morphoAdapter.setMarket(
                MarketParams({
                    loanToken: MAINNET_USDC,
                    collateralToken: MAINNET_WETH,
                    oracle: MAINNET_MORPHO_WETH_USDC_ORACLE,
                    irm: MAINNET_MORPHO_WETH_USDC_IRM,
                    lltv: MAINNET_MORPHO_WETH_USDC_LLTV
                })
            );
            // short ETH on Aave: collateral USDC, debt WETH
            aaveAdapter.setMarket(Currency.wrap(MAINNET_USDC), Currency.wrap(MAINNET_WETH), true);
            // long ETH on Aave: collateral WETH, debt USDC
            aaveAdapter.setMarket(Currency.wrap(MAINNET_WETH), Currency.wrap(MAINNET_USDC), true);
            console2.log("Registered canonical mainnet markets (Morpho long ETH, Aave short/long ETH)");
        } else {
            console2.log("Non-mainnet chain: skipped market registration, configure markets in a follow-up");
        }

        vm.stopBroadcast();

        console2.log("Governance can hand off via transferGovernance/acceptGovernance (router) and");
        console2.log("transferOwnership/acceptOwnership (adapters)");
    }
}
