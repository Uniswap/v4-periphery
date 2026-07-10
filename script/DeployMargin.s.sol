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
import {ISpoke} from "../src/interfaces/external/aave-v4/ISpoke.sol";

import {MarginRouter} from "../src/MarginRouter.sol";
import {MarginAccount} from "../src/MarginAccount.sol";
import {MorphoLendingAdapter} from "../src/MorphoLendingAdapter.sol";
import {AaveLendingAdapter} from "../src/AaveLendingAdapter.sol";
import {AaveV4LendingAdapter} from "../src/AaveV4LendingAdapter.sol";

/// @title DeployMargin
/// @notice Deploys the margin-trading suite: the deterministic MarginAccount implementation, the
///         Morpho, Aave v3, and Aave v4 lending adapters, and the MarginRouter at a mined vanity salt.
///         Wires the adapter allowlist and, on mainnet, registers the canonical markets.
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
    bytes32 internal constant AAVE_V4_ADAPTER_SALT = keccak256("uniswap.margin.AaveV4LendingAdapter.v1");

    // Verified mainnet token addresses, used only for the chainid == 1 market registration.
    address internal constant MAINNET_WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address internal constant MAINNET_USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    // Morpho WETH/USDC market (long ETH): collateral WETH, loan USDC. Params verified against
    // morpho.idToMarketParams for the canonical market id
    // 0x94b823e6bd8ea533b4e33fbc307faea0b307301bc48763acc4d4aa4def7636cd. Do NOT use oracle
    // 0xdC6fd583...: it hashes to an unlisted market (see FixMorphoWethUsdcMarket.s.sol).
    address internal constant MAINNET_MORPHO_WETH_USDC_ORACLE = 0x0F948CBa8231Db7898ef36A4212581Ad7b1B4580;
    address internal constant MAINNET_MORPHO_WETH_USDC_IRM = 0x870aC11D48B15DB9a138Cf899d20F13F79Ba00BC;
    uint256 internal constant MAINNET_MORPHO_WETH_USDC_LLTV = 0.86e18;
    // Aave v4 Main Spoke reserve ids (verified on-chain): WETH = 0, USDC = 5 on the Hub but reserveId 7
    // on the Main Spoke. Both reserves are on the Core Hub.
    uint256 internal constant MAINNET_AAVE_V4_WETH_RESERVE_ID = 0;
    uint256 internal constant MAINNET_AAVE_V4_USDC_RESERVE_ID = 7;

    function setUp() public {}

    /// @notice Deploys and wires the margin suite.
    /// @param poolManager The v4 PoolManager singleton the router unlocks for every position flow.
    /// @param permit2 The Permit2 contract used to pull caller equity and settle swaps.
    /// @param weth9 The canonical WETH9 used to wrap native ETH equity.
    /// @param governance The initial governance/owner of the router and adapters. MUST equal the
    ///        broadcaster so the inline allowlist and market wiring succeed.
    /// @param morpho The Morpho Blue singleton the Morpho adapter routes through.
    /// @param aaveProvider The Aave v3 PoolAddressesProvider the Aave v3 adapter resolves its Pool from.
    /// @param aaveV4Spoke The Aave v4 Spoke the Aave v4 adapter routes through (the Main Spoke on
    ///        mainnet).
    /// @param routerSalt The vanity salt from MineMarginRouterSalt, valid only for the exact
    ///        (poolManager, permit2, weth9, accountImpl, governance) tuple it was mined against.
    /// @return impl The deployed MarginAccount implementation.
    /// @return morphoAdapter The deployed Morpho lending adapter.
    /// @return aaveAdapter The deployed Aave v3 lending adapter.
    /// @return aaveV4Adapter The deployed Aave v4 lending adapter.
    /// @return router The deployed MarginRouter.
    function run(
        address poolManager,
        address permit2,
        address weth9,
        address governance,
        address morpho,
        address aaveProvider,
        address aaveV4Spoke,
        bytes32 routerSalt
    )
        public
        returns (
            MarginAccount impl,
            MorphoLendingAdapter morphoAdapter,
            AaveLendingAdapter aaveAdapter,
            AaveV4LendingAdapter aaveV4Adapter,
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

        aaveV4Adapter = new AaveV4LendingAdapter{salt: AAVE_V4_ADAPTER_SALT}(ISpoke(aaveV4Spoke), governance);
        console2.log("AaveV4LendingAdapter", address(aaveV4Adapter));

        // router at the mined vanity salt
        router = new MarginRouter{salt: routerSalt}(
            IPoolManager(poolManager), IAllowanceTransfer(permit2), IWETH9(weth9), address(impl), governance
        );
        console2.log("MarginRouter", address(router));

        // wire the allowlist; requires the broadcaster to be governance
        router.setAdapterAllowed(morphoAdapter, true);
        router.setAdapterAllowed(aaveAdapter, true);
        router.setAdapterAllowed(aaveV4Adapter, true);

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
            // short ETH on Aave v3: collateral USDC, debt WETH
            aaveAdapter.setMarket(Currency.wrap(MAINNET_USDC), Currency.wrap(MAINNET_WETH), true);
            // long ETH on Aave v3: collateral WETH, debt USDC
            aaveAdapter.setMarket(Currency.wrap(MAINNET_WETH), Currency.wrap(MAINNET_USDC), true);
            // short ETH on Aave v4 Main Spoke: collateral USDC (reserve 7), debt WETH (reserve 0)
            aaveV4Adapter.setMarket(
                Currency.wrap(MAINNET_USDC),
                Currency.wrap(MAINNET_WETH),
                MAINNET_AAVE_V4_USDC_RESERVE_ID,
                MAINNET_AAVE_V4_WETH_RESERVE_ID,
                true
            );
            // long ETH on Aave v4 Main Spoke: collateral WETH (reserve 0), debt USDC (reserve 7)
            aaveV4Adapter.setMarket(
                Currency.wrap(MAINNET_WETH),
                Currency.wrap(MAINNET_USDC),
                MAINNET_AAVE_V4_WETH_RESERVE_ID,
                MAINNET_AAVE_V4_USDC_RESERVE_ID,
                true
            );
            console2.log("Registered canonical mainnet markets (Morpho long ETH, Aave v3 + v4 short/long ETH)");
        } else {
            console2.log("Non-mainnet chain: skipped market registration, configure markets in a follow-up");
        }

        vm.stopBroadcast();

        console2.log("Governance can hand off via transferGovernance/acceptGovernance (router) and");
        console2.log("transferOwnership/acceptOwnership (adapters)");
    }
}
