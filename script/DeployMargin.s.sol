// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/console2.sol";

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IMorpho, MarketParams} from "morpho-blue/interfaces/IMorpho.sol";

import {IPoolAddressesProvider} from "../src/interfaces/external/aave/IPoolAddressesProvider.sol";
import {ISpoke} from "../src/interfaces/external/aave-v4/ISpoke.sol";
import {IComet} from "../src/interfaces/external/compound-v3/IComet.sol";

import {Market} from "../src/types/Market.sol";
import {ILendingAdapter} from "../src/interfaces/ILendingAdapter.sol";
import {IMarginRouter} from "../src/interfaces/IMarginRouter.sol";
import {MarginAccount} from "../src/MarginAccount.sol";
import {MorphoLendingAdapter} from "../src/MorphoLendingAdapter.sol";
import {AaveLendingAdapter} from "../src/AaveLendingAdapter.sol";
import {AaveV4LendingAdapter} from "../src/AaveV4LendingAdapter.sol";
import {CompoundV3LendingAdapter} from "../src/CompoundV3LendingAdapter.sol";

import {MarginDeployConfig} from "./MarginDeployConfig.sol";

/// @title DeployMargin
/// @notice Deploys the margin-trading suite: the deterministic MarginAccount implementation, the
///         Morpho, Aave v3, Aave v4, and Compound v3 lending adapters, and the MarginRouter at a mined
///         vanity salt. Wires the adapter allowlist and, on mainnet, registers the canonical markets.
/// @dev    Deployment notes:
///         - Idempotent. Every contract is deployed through the canonical CREATE2 deployer at a
///           deterministic address and skipped when that address already has code, and the allowlist
///           and market wiring are skipped when already set. A rerun after a partial deploy (or after
///           only the router's init code changed) broadcasts only what is missing. The guards never
///           rewrite existing state: changing an already-registered market route is a governance
///           action for a dedicated script (see FixMorphoWethUsdcMarket.s.sol), not a redeploy.
///         - The broadcaster MUST equal `governance`. The adapters are constructed with `governance`
///           as their owner and the router with `governance` as its governance, and this script then
///           calls `setAdapterAllowed` (router governance) and `setMarket` (adapter owner) inline.
///           Those calls revert unless the broadcasting key is `governance`. After setup, governance
///           can hand off each role via the two-step transferGovernance/acceptGovernance (router) and
///           transferOwnership/acceptOwnership (adapters).
///         - `routerSalt` comes from MineMarginRouterSalt and is only valid for the exact
///           (poolManager, permit2, weth9, accountImpl, governance) tuple it was mined against. The
///           accountImpl is itself derived from ACCOUNT_SALT, so the shared MarginDeployConfig
///           constants MUST match the miner; otherwise the mined router address will not be produced.
contract DeployMargin is MarginDeployConfig {
    /// @dev Fixed salts for the adapters. Their addresses need not be vanity, only deterministic.
    bytes32 internal constant MORPHO_ADAPTER_SALT = keccak256("uniswap.margin.MorphoLendingAdapter.v1");
    bytes32 internal constant AAVE_ADAPTER_SALT = keccak256("uniswap.margin.AaveLendingAdapter.v1");
    bytes32 internal constant AAVE_V4_ADAPTER_SALT = keccak256("uniswap.margin.AaveV4LendingAdapter.v1");
    bytes32 internal constant COMPOUND_ADAPTER_SALT = keccak256("uniswap.margin.CompoundV3LendingAdapter.v1");

    // Verified mainnet token addresses, used only for the chainid == 1 market registration.
    address internal constant MAINNET_USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address internal constant MAINNET_UNI = 0x1f9840a85d5aF5bf1D1762F925BDADdC4201F984;
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

    /// @notice Deploys and wires the margin suite. Skips anything already deployed or wired, so a
    ///         partially completed deployment can be resumed by rerunning with the same arguments.
    /// @param poolManager The v4 PoolManager singleton the router unlocks for every position flow.
    /// @param permit2 The Permit2 contract used to pull caller equity and settle swaps.
    /// @param weth9 The canonical WETH9 used to wrap native ETH equity.
    /// @param governance The initial governance/owner of the router and adapters. MUST equal the
    ///        broadcaster so the inline allowlist and market wiring succeed.
    /// @param morpho The Morpho Blue singleton the Morpho adapter routes through.
    /// @param aaveProvider The Aave v3 PoolAddressesProvider the Aave v3 adapter resolves its Pool from.
    /// @param aaveV4Spoke The Aave v4 Spoke the Aave v4 adapter routes through (the Main Spoke on
    ///        mainnet).
    /// @param compoundComet The Compound v3 Comet the Compound adapter routes through (the USDC Comet
    ///        on mainnet).
    /// @param routerSalt The vanity salt from MineMarginRouterSalt, valid only for the exact
    ///        (poolManager, permit2, weth9, accountImpl, governance) tuple it was mined against. The
    ///        Universal Router is no longer a constructor arg (callers pass it per swap), so it does not
    ///        affect the router address.
    /// @return impl The MarginAccount implementation.
    /// @return morphoAdapter The Morpho lending adapter.
    /// @return aaveAdapter The Aave v3 lending adapter.
    /// @return aaveV4Adapter The Aave v4 lending adapter.
    /// @return compoundAdapter The Compound v3 lending adapter.
    /// @return router The MarginRouter.
    function run(
        address poolManager,
        address permit2,
        address weth9,
        address governance,
        address morpho,
        address aaveProvider,
        address aaveV4Spoke,
        address compoundComet,
        bytes32 routerSalt
    )
        public
        returns (
            MarginAccount impl,
            MorphoLendingAdapter morphoAdapter,
            AaveLendingAdapter aaveAdapter,
            AaveV4LendingAdapter aaveV4Adapter,
            CompoundV3LendingAdapter compoundAdapter,
            IMarginRouter router
        )
    {
        vm.startBroadcast();

        // deterministic account implementation; its address must match the miner's derivation so the
        // router lands at the mined vanity salt
        impl = MarginAccount(
            payable(_deployDeterministic(
                    "MarginAccount implementation", ACCOUNT_SALT, type(MarginAccount).creationCode
                ))
        );

        // adapters owned by governance
        morphoAdapter = MorphoLendingAdapter(
            _deployDeterministic(
                "MorphoLendingAdapter",
                MORPHO_ADAPTER_SALT,
                abi.encodePacked(type(MorphoLendingAdapter).creationCode, abi.encode(morpho, governance))
            )
        );

        aaveAdapter = AaveLendingAdapter(
            _deployDeterministic(
                "AaveLendingAdapter",
                AAVE_ADAPTER_SALT,
                abi.encodePacked(type(AaveLendingAdapter).creationCode, abi.encode(aaveProvider, governance))
            )
        );

        aaveV4Adapter = AaveV4LendingAdapter(
            _deployDeterministic(
                "AaveV4LendingAdapter",
                AAVE_V4_ADAPTER_SALT,
                abi.encodePacked(type(AaveV4LendingAdapter).creationCode, abi.encode(aaveV4Spoke, governance))
            )
        );

        compoundAdapter = CompoundV3LendingAdapter(
            _deployDeterministic(
                "CompoundV3LendingAdapter",
                COMPOUND_ADAPTER_SALT,
                abi.encodePacked(type(CompoundV3LendingAdapter).creationCode, abi.encode(compoundComet, governance))
            )
        );

        // router at the mined vanity salt. getCode reads the router's optimizer-restricted artifact
        // so the deployed runtime fits under EIP-170; `new` would embed the oversized default-profile
        // bytecode. The Universal Router is not a constructor arg (callers pass it per swap), so it is
        // not in the init code.
        bytes memory routerInitCode = abi.encodePacked(
            vm.getCode("MarginRouter.sol:MarginRouter"),
            abi.encode(poolManager, permit2, weth9, address(impl), governance)
        );
        router = IMarginRouter(_deployDeterministic("MarginRouter", routerSalt, routerInitCode));

        // wire the allowlist; requires the broadcaster to be governance
        _ensureAdapterAllowed(router, morphoAdapter);
        _ensureAdapterAllowed(router, aaveAdapter);
        _ensureAdapterAllowed(router, aaveV4Adapter);
        _ensureAdapterAllowed(router, compoundAdapter);

        if (block.chainid == 1) {
            // long ETH on Morpho: collateral WETH, debt USDC
            if (!morphoAdapter.isSupportedMarket(_market(MAINNET_WETH, MAINNET_USDC))) {
                morphoAdapter.setMarket(
                    MarketParams({
                        loanToken: MAINNET_USDC,
                        collateralToken: MAINNET_WETH,
                        oracle: MAINNET_MORPHO_WETH_USDC_ORACLE,
                        irm: MAINNET_MORPHO_WETH_USDC_IRM,
                        lltv: MAINNET_MORPHO_WETH_USDC_LLTV
                    })
                );
            }
            // short ETH on Aave v3: collateral USDC, debt WETH
            if (!aaveAdapter.isSupportedMarket(_market(MAINNET_USDC, MAINNET_WETH))) {
                aaveAdapter.setMarket(Currency.wrap(MAINNET_USDC), Currency.wrap(MAINNET_WETH), true);
            }
            // long ETH on Aave v3: collateral WETH, debt USDC
            if (!aaveAdapter.isSupportedMarket(_market(MAINNET_WETH, MAINNET_USDC))) {
                aaveAdapter.setMarket(Currency.wrap(MAINNET_WETH), Currency.wrap(MAINNET_USDC), true);
            }
            // short ETH on Aave v4 Main Spoke: collateral USDC (reserve 7), debt WETH (reserve 0)
            if (!aaveV4Adapter.isSupportedMarket(_market(MAINNET_USDC, MAINNET_WETH))) {
                aaveV4Adapter.setMarket(
                    Currency.wrap(MAINNET_USDC),
                    Currency.wrap(MAINNET_WETH),
                    MAINNET_AAVE_V4_USDC_RESERVE_ID,
                    MAINNET_AAVE_V4_WETH_RESERVE_ID,
                    true
                );
            }
            // long ETH on Aave v4 Main Spoke: collateral WETH (reserve 0), debt USDC (reserve 7)
            if (!aaveV4Adapter.isSupportedMarket(_market(MAINNET_WETH, MAINNET_USDC))) {
                aaveV4Adapter.setMarket(
                    Currency.wrap(MAINNET_WETH),
                    Currency.wrap(MAINNET_USDC),
                    MAINNET_AAVE_V4_WETH_RESERVE_ID,
                    MAINNET_AAVE_V4_USDC_RESERVE_ID,
                    true
                );
            }
            // long UNI on Compound v3: collateral UNI, debt USDC (the Comet base)
            if (!compoundAdapter.isSupportedMarket(_market(MAINNET_UNI, MAINNET_USDC))) {
                compoundAdapter.setMarket(Currency.wrap(MAINNET_UNI), Currency.wrap(MAINNET_USDC), true);
            }
            console2.log(
                "Ensured canonical mainnet markets (Morpho long ETH, Aave v3 + v4 short/long ETH, Compound long UNI)"
            );
        } else {
            console2.log("Non-mainnet chain: skipped market registration, configure markets in a follow-up");
        }

        vm.stopBroadcast();

        console2.log("Governance can hand off via transferGovernance/acceptGovernance (router) and");
        console2.log("transferOwnership/acceptOwnership (adapters)");
    }

    /// @notice Deploys `initCode` at its deterministic address through the canonical CREATE2
    ///         deployer, or reuses the existing deployment when that address already has code.
    /// @dev The explicit factory call (rather than a source-level `new X{salt}`) deploys from the
    ///      same factory MineMarginRouterSalt / create2crunch mine against, and lets the router use
    ///      init code read via `vm.getCode`. Skipping on existing code is what makes reruns and
    ///      partial-deploy resumes possible: a CREATE2 collision would otherwise revert the script.
    function _deployDeterministic(string memory name, bytes32 salt, bytes memory initCode)
        internal
        returns (address addr)
    {
        addr = vm.computeCreate2Address(salt, keccak256(initCode), CREATE2_DEPLOYER);
        if (addr.code.length != 0) {
            console2.log(string.concat(name, " (already deployed)"), addr);
            return addr;
        }
        (bool ok,) = CREATE2_DEPLOYER.call(bytes.concat(salt, initCode));
        require(ok && addr.code.length != 0, string.concat(name, " deploy failed"));
        console2.log(name, addr);
    }

    /// @notice Allowlists `adapter` on the router unless it is already allowed, so reruns do not
    ///         re-send no-op governance transactions.
    function _ensureAdapterAllowed(IMarginRouter router, ILendingAdapter adapter) internal {
        if (!router.isAdapterAllowed(adapter)) router.setAdapterAllowed(adapter, true);
    }

    /// @notice Builds the adapter-facing market descriptor for an `isSupportedMarket` guard.
    function _market(address collateral, address debt) internal pure returns (Market memory) {
        return Market({collateral: Currency.wrap(collateral), debt: Currency.wrap(debt)});
    }
}
