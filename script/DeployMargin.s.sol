// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/console2.sol";

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
///         vanity salt. There is nothing to wire afterwards: the router has no governance and no
///         adapter allowlist, and market selection is permissionless, so callers name the adapter and
///         any live venue market (through `Market.data`) per call and the adapters validate the market.
/// @dev    Deployment notes:
///         - Idempotent. Every contract is deployed through the canonical CREATE2 deployer at a
///           deterministic address and skipped when that address already has code. A rerun after a
///           partial deploy (or after only the router's init code changed) broadcasts only what is
///           missing. Any key can broadcast; no address is baked in as an owner.
///         - The adapters are stateless and unowned: each binds its venue singleton at construction
///           and holds no routing table, so nothing in the suite is configurable after deployment.
///         - `routerSalt` comes from MineMarginRouterSalt and is only valid for the exact
///           (poolManager, permit2, weth9, accountImpl) tuple it was mined against. The accountImpl is
///           itself derived from ACCOUNT_SALT, so the shared MarginDeployConfig constants MUST match
///           the miner; otherwise the mined router address will not be produced.
contract DeployMargin is MarginDeployConfig {
    /// @dev Fixed salts for the adapters. Their addresses need not be vanity, only deterministic.
    bytes32 internal constant MORPHO_ADAPTER_SALT = keccak256("uniswap.margin.MorphoLendingAdapter.v1");
    bytes32 internal constant AAVE_ADAPTER_SALT = keccak256("uniswap.margin.AaveLendingAdapter.v1");
    bytes32 internal constant AAVE_V4_ADAPTER_SALT = keccak256("uniswap.margin.AaveV4LendingAdapter.v1");
    bytes32 internal constant COMPOUND_ADAPTER_SALT = keccak256("uniswap.margin.CompoundV3LendingAdapter.v1");

    function setUp() public {}

    /// @notice Deploys and wires the margin suite. Skips anything already deployed or wired, so a
    ///         partially completed deployment can be resumed by rerunning with the same arguments.
    /// @param poolManager The v4 PoolManager singleton the router unlocks for every position flow.
    /// @param permit2 The Permit2 contract used to pull caller equity and settle swaps.
    /// @param weth9 The canonical WETH9 used to wrap native ETH equity.
    /// @param morpho The Morpho Blue singleton the Morpho adapter routes through.
    /// @param aaveProvider The Aave v3 PoolAddressesProvider the Aave v3 adapter resolves its Pool from.
    /// @param aaveV4Spoke The Aave v4 Spoke the Aave v4 adapter routes through (the Main Spoke on
    ///        mainnet).
    /// @param compoundComet The Compound v3 Comet the Compound adapter routes through (the USDC Comet
    ///        on mainnet).
    /// @param routerSalt The vanity salt from MineMarginRouterSalt, valid only for the exact
    ///        (poolManager, permit2, weth9, accountImpl) tuple it was mined against. The
    ///        Universal Router is not a constructor arg (callers pass it per swap), so it does not
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

        // stateless, unowned adapters: each binds only its venue singleton
        morphoAdapter = MorphoLendingAdapter(
            _deployDeterministic(
                "MorphoLendingAdapter",
                MORPHO_ADAPTER_SALT,
                abi.encodePacked(type(MorphoLendingAdapter).creationCode, abi.encode(morpho))
            )
        );

        aaveAdapter = AaveLendingAdapter(
            _deployDeterministic(
                "AaveLendingAdapter",
                AAVE_ADAPTER_SALT,
                abi.encodePacked(type(AaveLendingAdapter).creationCode, abi.encode(aaveProvider))
            )
        );

        aaveV4Adapter = AaveV4LendingAdapter(
            _deployDeterministic(
                "AaveV4LendingAdapter",
                AAVE_V4_ADAPTER_SALT,
                abi.encodePacked(type(AaveV4LendingAdapter).creationCode, abi.encode(aaveV4Spoke))
            )
        );

        compoundAdapter = CompoundV3LendingAdapter(
            _deployDeterministic(
                "CompoundV3LendingAdapter",
                COMPOUND_ADAPTER_SALT,
                abi.encodePacked(type(CompoundV3LendingAdapter).creationCode, abi.encode(compoundComet))
            )
        );

        // router at the mined vanity salt. getCode reads the router's optimizer-restricted artifact
        // so the deployed runtime fits under EIP-170; `new` would embed the oversized default-profile
        // bytecode. The Universal Router is not a constructor arg (callers pass it per swap), so it is
        // not in the init code.
        bytes memory routerInitCode = abi.encodePacked(
            vm.getCode("MarginRouter.sol:MarginRouter"), abi.encode(poolManager, permit2, weth9, address(impl))
        );
        router = IMarginRouter(_deployDeterministic("MarginRouter", routerSalt, routerInitCode));

        vm.stopBroadcast();

        console2.log("No post-deploy wiring: the router has no governance or adapter allowlist, and");
        console2.log("market selection is permissionless (callers name the adapter and market per call)");
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
}
