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

    /// @notice External protocol dependencies the stack is wired against.
    struct Deps {
        address poolManager;
        address permit2;
        address weth9;
        address morpho;
        address aaveProvider;
        address aaveV4Spoke;
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

    /// @notice The deterministic addresses the batch will deploy.
    struct Deployed {
        address impl;
        address morphoAdapter;
        address aaveAdapter;
        address aaveV4Adapter;
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
        addrs.router = _create2(routerSalt, _routerInit(deps, addrs.impl, governance));
    }

    /// @notice Builds the full deploy-and-bootstrap batch and the addresses it produces.
    /// @param deps The external protocol dependencies.
    /// @param governance The bootstrap owner/governance (the deploying EOA) that wires the stack.
    /// @param routerSalt The mined vanity salt for the router.
    /// @param morphoMarkets The Morpho markets to register (must already exist on Morpho Blue).
    /// @param v3Markets The Aave v3 pairs to allowlist.
    /// @param v4Markets The Aave v4 pairs (with reserve ids) to register.
    /// @param finalGovernance The address to propose as the eventual governance/owner; pass the same
    ///        value as `governance` (or the zero address) to skip the handoff and leave the deployer
    ///        in control.
    /// @return calls The ordered batch for `BatchExecutor.execute`.
    /// @return addrs The deterministic deployed addresses.
    function buildPlan(
        Deps memory deps,
        address governance,
        bytes32 routerSalt,
        MarketParams[] memory morphoMarkets,
        AaveV3Market[] memory v3Markets,
        AaveV4Market[] memory v4Markets,
        address finalGovernance
    ) public view returns (BatchExecutor.Call[] memory calls, Deployed memory addrs) {
        addrs = computeAddresses(deps, governance, routerSalt);

        bool handoff = finalGovernance != address(0) && finalGovernance != governance;
        // 5 deploys + 3 allowlist + per-market registrations + (4 handoff calls when handing off)
        uint256 n = 5 + 3 + morphoMarkets.length + v3Markets.length + v4Markets.length + (handoff ? 4 : 0);
        calls = new BatchExecutor.Call[](n);
        uint256 k;

        // deploys, in the order the addresses depend on (impl before router)
        calls[k++] = _deploy(ACCOUNT_SALT, _implInit());
        calls[k++] = _deploy(MORPHO_ADAPTER_SALT, _morphoInit(deps.morpho, governance));
        calls[k++] = _deploy(AAVE_ADAPTER_SALT, _aaveInit(deps.aaveProvider, governance));
        calls[k++] = _deploy(AAVE_V4_ADAPTER_SALT, _aaveV4Init(deps.aaveV4Spoke, governance));
        calls[k++] = _deploy(routerSalt, _routerInit(deps, addrs.impl, governance));

        // allowlist every adapter (executed as `governance`)
        calls[k++] = _call(addrs.router, _allow(addrs.morphoAdapter));
        calls[k++] = _call(addrs.router, _allow(addrs.aaveAdapter));
        calls[k++] = _call(addrs.router, _allow(addrs.aaveV4Adapter));

        // register the supplied markets on each adapter (executed as `governance`)
        for (uint256 i; i < morphoMarkets.length; i++) {
            calls[k++] = _call(addrs.morphoAdapter, abi.encodeCall(MorphoLendingAdapter.setMarket, (morphoMarkets[i])));
        }
        for (uint256 i; i < v3Markets.length; i++) {
            calls[k++] = _call(
                addrs.aaveAdapter,
                abi.encodeCall(AaveLendingAdapter.setMarket, (v3Markets[i].collateral, v3Markets[i].debt, true))
            );
        }
        for (uint256 i; i < v4Markets.length; i++) {
            calls[k++] = _call(
                addrs.aaveV4Adapter,
                abi.encodeCall(
                    AaveV4LendingAdapter.setMarket,
                    (
                        v4Markets[i].collateral,
                        v4Markets[i].debt,
                        v4Markets[i].collateralReserveId,
                        v4Markets[i].debtReserveId,
                        true
                    )
                )
            );
        }

        // propose the real governance/owner everywhere (two-step; the recipient accepts later)
        if (handoff) {
            calls[k++] = _call(addrs.router, abi.encodeCall(MarginRouter.transferGovernance, (finalGovernance)));
            bytes memory transferOwner = abi.encodeWithSignature("transferOwnership(address)", finalGovernance);
            calls[k++] = _call(addrs.morphoAdapter, transferOwner);
            calls[k++] = _call(addrs.aaveAdapter, transferOwner);
            calls[k++] = _call(addrs.aaveV4Adapter, transferOwner);
        }
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
