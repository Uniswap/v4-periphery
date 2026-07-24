// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {CommonBase} from "forge-std/Base.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {MarketParams} from "morpho-blue/interfaces/IMorpho.sol";

import {ILendingAdapter} from "../src/interfaces/ILendingAdapter.sol";
import {MarginRouter} from "../src/MarginRouter.sol";
import {MorphoLendingAdapter} from "../src/MorphoLendingAdapter.sol";
import {AaveLendingAdapter} from "../src/AaveLendingAdapter.sol";
import {AaveV4LendingAdapter} from "../src/AaveV4LendingAdapter.sol";
import {CompoundV3LendingAdapter} from "../src/CompoundV3LendingAdapter.sol";
import {BatchExecutor} from "./BatchExecutor.sol";

/// @title MarginBootstrapBuilder
/// @author Uniswap Labs
/// @notice Builds the ordered `BatchExecutor.Call[]` that deploys and bootstraps the entire margin
///         stack in one EIP-7702 transaction, and computes the deterministic addresses the deploy
///         will produce. Shared by the deploy script and its test so both derive addresses and the
///         call plan the same way.
/// @dev Every contract is deployed through the standard CREATE2 factory (a CALL carrying
///      `salt ++ initCode`), so addresses match `MineMarginRouterSalt` exactly and the router keeps
///      its mined vanity address. `governance` is the bootstrap owner (the deploying EOA) so the
///      inline allowlist and `setMarket` calls succeed; a distinct `finalGovernance` is proposed at
///      the end via the two-step handoff. Creation code is read at runtime via `vm.getCode`, so this
///      builder's own bytecode stays small (it does not embed the stack's 55KB of creation code).
contract MarginBootstrapBuilder is CommonBase {
    // CREATE2_FACTORY (0x4e59...) is inherited from forge-std CommonBase; the batch deploys through it
    // so addresses match MineMarginRouterSalt and the router keeps its mined vanity address.

    /// @dev Deterministic salts, matching MineMarginRouterSalt and the legacy DeployMargin script so
    ///      the addresses (and the router init-code hash the vanity salt was mined against) line up.
    bytes32 internal constant ACCOUNT_SALT = keccak256("uniswap.margin.MarginAccount.v1");
    bytes32 internal constant MORPHO_ADAPTER_SALT = keccak256("uniswap.margin.MorphoLendingAdapter.v1");
    bytes32 internal constant AAVE_ADAPTER_SALT = keccak256("uniswap.margin.AaveLendingAdapter.v1");
    bytes32 internal constant AAVE_V4_ADAPTER_SALT = keccak256("uniswap.margin.AaveV4LendingAdapter.v1");
    bytes32 internal constant COMPOUND_ADAPTER_SALT = keccak256("uniswap.margin.CompoundV3LendingAdapter.v1");

    /// @notice External protocol dependencies the stack is wired against.
    struct Deps {
        address poolManager;
        address permit2;
        address weth9;
        address morpho;
        address aaveProvider;
        address aaveV4Spoke;
        address compoundComet;
    }

    /// @notice An Aave v3 `(collateral, debt)` pair to allowlist.
    struct AaveV3Market {
        Currency collateral;
        Currency debt;
    }

    /// @notice An Aave v4 `(collateral, debt)` pair plus its Spoke reserve ids to register.
    struct AaveV4Market {
        Currency collateral;
        Currency debt;
        uint256 collateralReserveId;
        uint256 debtReserveId;
    }

    /// @notice A Compound v3 `(collateral, debt)` pair to allowlist. `debt` must be the bound Comet's
    ///         base token and `collateral` a registered Comet collateral asset (the adapter validates).
    struct CompoundMarket {
        Currency collateral;
        Currency debt;
    }

    /// @notice The markets to register on each adapter, bundled so the plan builder takes one argument
    ///         per concern rather than one per venue (and to keep the builder within the stack limit
    ///         under the non-via-IR test profile).
    struct Markets {
        MarketParams[] morpho;
        AaveV3Market[] v3;
        AaveV4Market[] v4;
        CompoundMarket[] compound;
    }

    /// @notice The deterministic addresses the batch will deploy.
    struct Deployed {
        address impl;
        address morphoAdapter;
        address aaveAdapter;
        address aaveV4Adapter;
        address compoundAdapter;
        address router;
    }

    /// @notice Computes the addresses the deploy will produce, without building the call plan.
    /// @param deps The external protocol dependencies.
    /// @param governance The bootstrap owner/governance baked into the router and adapters.
    /// @param routerSalt The mined vanity salt for the router.
    /// @return addrs The deterministic deployed addresses.
    function computeAddresses(Deps memory deps, address governance, bytes32 routerSalt)
        public
        view
        returns (Deployed memory addrs)
    {
        addrs.impl = _create2(ACCOUNT_SALT, _implInit());
        addrs.morphoAdapter = _create2(MORPHO_ADAPTER_SALT, _morphoInit(deps.morpho, governance));
        addrs.aaveAdapter = _create2(AAVE_ADAPTER_SALT, _aaveInit(deps.aaveProvider, governance));
        addrs.aaveV4Adapter = _create2(AAVE_V4_ADAPTER_SALT, _aaveV4Init(deps.aaveV4Spoke, governance));
        addrs.compoundAdapter = _create2(COMPOUND_ADAPTER_SALT, _compoundInit(deps.compoundComet, governance));
        addrs.router = _create2(routerSalt, _routerInit(deps, addrs.impl, governance));
    }

    /// @notice Builds the full deploy-and-bootstrap batch and the addresses it produces.
    /// @param deps The external protocol dependencies.
    /// @param governance The bootstrap owner/governance (the deploying EOA) that wires the stack.
    /// @param routerSalt The mined vanity salt for the router.
    /// @param markets The markets to register on each adapter (Morpho markets must already exist on
    ///        Morpho Blue; Compound pairs' debt must be the Comet base).
    /// @param finalGovernance The address to propose as the eventual governance/owner; pass the same
    ///        value as `governance` (or the zero address) to skip the handoff and leave the deployer
    ///        in control.
    /// @return calls The ordered batch for `BatchExecutor.execute`.
    /// @return addrs The deterministic deployed addresses.
    function buildPlan(
        Deps memory deps,
        address governance,
        bytes32 routerSalt,
        Markets memory markets,
        address finalGovernance
    ) public view returns (BatchExecutor.Call[] memory calls, Deployed memory addrs) {
        addrs = computeAddresses(deps, governance, routerSalt);

        bool handoff = finalGovernance != address(0) && finalGovernance != governance;
        // 6 deploys + 4 allowlist + per-market registrations + (5 handoff calls when handing off)
        uint256 n = 6 + 4 + markets.morpho.length + markets.v3.length + markets.v4.length + markets.compound.length
            + (handoff ? 5 : 0);
        calls = new BatchExecutor.Call[](n);
        uint256 k = _appendDeploys(calls, deps, governance, routerSalt, addrs);
        k = _appendAllowlist(calls, k, addrs);
        k = _appendMarkets(calls, k, addrs, markets);
        if (handoff) _appendHandoff(calls, k, addrs, finalGovernance);
    }

    /// @dev Appends the six CREATE2 deploys in dependency order (impl before router). Returns the next
    ///      free index.
    function _appendDeploys(
        BatchExecutor.Call[] memory calls,
        Deps memory deps,
        address governance,
        bytes32 routerSalt,
        Deployed memory addrs
    ) internal view returns (uint256 k) {
        calls[k++] = _deploy(ACCOUNT_SALT, _implInit());
        calls[k++] = _deploy(MORPHO_ADAPTER_SALT, _morphoInit(deps.morpho, governance));
        calls[k++] = _deploy(AAVE_ADAPTER_SALT, _aaveInit(deps.aaveProvider, governance));
        calls[k++] = _deploy(AAVE_V4_ADAPTER_SALT, _aaveV4Init(deps.aaveV4Spoke, governance));
        calls[k++] = _deploy(COMPOUND_ADAPTER_SALT, _compoundInit(deps.compoundComet, governance));
        calls[k++] = _deploy(routerSalt, _routerInit(deps, addrs.impl, governance));
    }

    /// @dev Appends an allowlist call for every adapter (executed as `governance`).
    function _appendAllowlist(BatchExecutor.Call[] memory calls, uint256 k, Deployed memory addrs)
        internal
        pure
        returns (uint256)
    {
        calls[k++] = _call(addrs.router, _allow(addrs.morphoAdapter));
        calls[k++] = _call(addrs.router, _allow(addrs.aaveAdapter));
        calls[k++] = _call(addrs.router, _allow(addrs.aaveV4Adapter));
        calls[k++] = _call(addrs.router, _allow(addrs.compoundAdapter));
        return k;
    }

    /// @dev Appends the per-market registration calls on each adapter (executed as `governance`).
    function _appendMarkets(BatchExecutor.Call[] memory calls, uint256 k, Deployed memory addrs, Markets memory markets)
        internal
        pure
        returns (uint256)
    {
        for (uint256 i; i < markets.morpho.length; i++) {
            calls[k++] = _call(addrs.morphoAdapter, abi.encodeCall(MorphoLendingAdapter.setMarket, (markets.morpho[i])));
        }
        for (uint256 i; i < markets.v3.length; i++) {
            calls[k++] = _call(
                addrs.aaveAdapter,
                abi.encodeCall(AaveLendingAdapter.setMarket, (markets.v3[i].collateral, markets.v3[i].debt, true))
            );
        }
        for (uint256 i; i < markets.v4.length; i++) {
            calls[k++] = _call(
                addrs.aaveV4Adapter,
                abi.encodeCall(
                    AaveV4LendingAdapter.setMarket,
                    (
                        markets.v4[i].collateral,
                        markets.v4[i].debt,
                        markets.v4[i].collateralReserveId,
                        markets.v4[i].debtReserveId,
                        true
                    )
                )
            );
        }
        for (uint256 i; i < markets.compound.length; i++) {
            calls[k++] = _call(
                addrs.compoundAdapter,
                abi.encodeCall(
                    CompoundV3LendingAdapter.setMarket, (markets.compound[i].collateral, markets.compound[i].debt, true)
                )
            );
        }
        return k;
    }

    /// @dev Appends the two-step governance/ownership handoff proposals (the recipient accepts later).
    function _appendHandoff(
        BatchExecutor.Call[] memory calls,
        uint256 k,
        Deployed memory addrs,
        address finalGovernance
    ) internal pure {
        calls[k++] = _call(addrs.router, abi.encodeCall(MarginRouter.transferGovernance, (finalGovernance)));
        bytes memory transferOwner = abi.encodeWithSignature("transferOwnership(address)", finalGovernance);
        calls[k++] = _call(addrs.morphoAdapter, transferOwner);
        calls[k++] = _call(addrs.aaveAdapter, transferOwner);
        calls[k++] = _call(addrs.aaveV4Adapter, transferOwner);
        calls[k++] = _call(addrs.compoundAdapter, transferOwner);
    }

    // ===== init code =====

    function _implInit() internal view returns (bytes memory) {
        return vm.getCode("MarginAccount.sol:MarginAccount");
    }

    function _morphoInit(address morpho, address governance) internal view returns (bytes memory) {
        return bytes.concat(vm.getCode("MorphoLendingAdapter.sol:MorphoLendingAdapter"), abi.encode(morpho, governance));
    }

    function _aaveInit(address aaveProvider, address governance) internal view returns (bytes memory) {
        return
            bytes.concat(vm.getCode("AaveLendingAdapter.sol:AaveLendingAdapter"), abi.encode(aaveProvider, governance));
    }

    function _aaveV4Init(address aaveV4Spoke, address governance) internal view returns (bytes memory) {
        return
            bytes.concat(
                vm.getCode("AaveV4LendingAdapter.sol:AaveV4LendingAdapter"), abi.encode(aaveV4Spoke, governance)
            );
    }

    function _compoundInit(address compoundComet, address governance) internal view returns (bytes memory) {
        return bytes.concat(
            vm.getCode("CompoundV3LendingAdapter.sol:CompoundV3LendingAdapter"), abi.encode(compoundComet, governance)
        );
    }

    function _routerInit(Deps memory deps, address impl, address governance) internal view returns (bytes memory) {
        return bytes.concat(
            vm.getCode("MarginRouter.sol:MarginRouter"),
            abi.encode(deps.poolManager, deps.permit2, deps.weth9, impl, governance)
        );
    }

    // ===== helpers =====

    /// @dev A CREATE2 deploy call through the standard factory: calldata is `salt ++ initCode`.
    function _deploy(bytes32 salt, bytes memory initCode) internal pure returns (BatchExecutor.Call memory) {
        return BatchExecutor.Call({target: CREATE2_FACTORY, value: 0, data: bytes.concat(salt, initCode)});
    }

    /// @dev A plain config call to a deployed contract.
    function _call(address target, bytes memory data) internal pure returns (BatchExecutor.Call memory) {
        return BatchExecutor.Call({target: target, value: 0, data: data});
    }

    function _allow(address adapter) internal pure returns (bytes memory) {
        return abi.encodeCall(MarginRouter.setAdapterAllowed, (ILendingAdapter(adapter), true));
    }

    /// @dev The address the factory produces for `initCode` at `salt`.
    function _create2(bytes32 salt, bytes memory initCode) internal pure returns (address) {
        return address(
            uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), CREATE2_FACTORY, salt, keccak256(initCode)))))
        );
    }
}
