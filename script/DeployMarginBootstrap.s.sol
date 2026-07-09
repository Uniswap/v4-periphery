// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "forge-std/console2.sol";
import {Script} from "forge-std/Script.sol";

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {MarketParams} from "morpho-blue/interfaces/IMorpho.sol";

import {BatchExecutor} from "./BatchExecutor.sol";
import {MarginBootstrapBuilder} from "./MarginBootstrapBuilder.sol";

/// @title DeployMarginBootstrap
/// @notice Deploys and bootstraps the entire margin stack in a single EIP-7702 transaction. The
///         deployer EOA delegates to a reusable BatchExecutor and, in one self-call, deploys the
///         account implementation, the three adapters, and the router (all through the standard
///         CREATE2 factory, so the router keeps its mined vanity address), then allowlists the
///         adapters, registers the canonical markets, and proposes `finalGovernance` via the two-step
///         handoff.
/// @dev The BatchExecutor is one-time reusable infrastructure; this script deploys it (at a
///      deterministic address) only if it is not already present, then sends the single bootstrap
///      transaction. The router salt MUST have been mined (MineMarginRouterSalt) with
///      `governance == the deployer EOA`, since the EOA is the bootstrap governance baked into the
///      router init code. Requires a chain with EIP-7702 (mainnet, Base, ...); the broadcast fails
///      loudly if the chain rejects the type-4 transaction.
///
///      After the deploy, the deployer EOA still carries the 7702 delegation to the executor until it
///      is reset. Use a throwaway deployer key, or reset the delegation
///      (`vm.signAndAttachDelegation(address(0), pk)` in a follow-up tx).
contract DeployMarginBootstrap is Script, MarginBootstrapBuilder {
    /// @dev Deterministic salt for the reusable BatchExecutor.
    bytes32 internal constant EXECUTOR_SALT = keccak256("uniswap.margin.BatchExecutor.v1");

    // Verified mainnet token addresses, used only for the chainid == 1 market registration.
    address internal constant MAINNET_WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address internal constant MAINNET_USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address internal constant MAINNET_MORPHO_WETH_USDC_ORACLE = 0xdC6fd5831277c693b1054e19E94047cB37c77615;
    address internal constant MAINNET_MORPHO_WETH_USDC_IRM = 0x870aC11D48B15DB9a138Cf899d20F13F79Ba00BC;
    uint256 internal constant MAINNET_MORPHO_WETH_USDC_LLTV = 0.86e18;
    uint256 internal constant MAINNET_AAVE_V4_WETH_RESERVE_ID = 0;
    uint256 internal constant MAINNET_AAVE_V4_USDC_RESERVE_ID = 7;

    /// @notice Deploys and bootstraps the stack in one tx.
    /// @param poolManager The v4 PoolManager the router unlocks.
    /// @param permit2 The Permit2 contract.
    /// @param weth9 The canonical WETH9.
    /// @param morpho The Morpho Blue singleton.
    /// @param aaveProvider The Aave v3 PoolAddressesProvider.
    /// @param aaveV4Spoke The Aave v4 Spoke.
    /// @param finalGovernance The eventual governance/owner proposed via the two-step handoff; pass the
    ///        deployer address (or zero) to skip the handoff and leave the deployer in control.
    /// @param routerSalt The mined vanity salt for the router (mined with governance == deployer).
    function run(
        address poolManager,
        address permit2,
        address weth9,
        address morpho,
        address aaveProvider,
        address aaveV4Spoke,
        address finalGovernance,
        bytes32 routerSalt
    ) public {
        uint256 deployerPk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerPk);

        Deps memory deps = Deps({
            poolManager: poolManager,
            permit2: permit2,
            weth9: weth9,
            morpho: morpho,
            aaveProvider: aaveProvider,
            aaveV4Spoke: aaveV4Spoke
        });

        // reusable executor at a deterministic address; deploy only if absent (one-time infra)
        address executor = _create2(EXECUTOR_SALT, vm.getCode("BatchExecutor.sol:BatchExecutor"));
        if (executor.code.length == 0) {
            vm.broadcast(deployerPk);
            address deployed = address(new BatchExecutor{salt: EXECUTOR_SALT}());
            require(deployed == executor, "executor address mismatch");
            console2.log("BatchExecutor deployed", executor);
        } else {
            console2.log("BatchExecutor already present", executor);
        }

        (MarketParams[] memory morphoMarkets, AaveV3Market[] memory v3Markets, AaveV4Market[] memory v4Markets) =
            _markets();

        (BatchExecutor.Call[] memory calls, Deployed memory addrs) =
            buildPlan(deps, deployer, routerSalt, morphoMarkets, v3Markets, v4Markets, finalGovernance);

        // the single deploy-and-bootstrap transaction: delegate the EOA to the executor (7702) and
        // self-call execute() with the whole plan
        vm.startBroadcast(deployerPk);
        vm.signAndAttachDelegation(executor, deployerPk);
        BatchExecutor(payable(deployer)).execute(calls);
        vm.stopBroadcast();

        console2.log("MarginAccount implementation", addrs.impl);
        console2.log("MorphoLendingAdapter", addrs.morphoAdapter);
        console2.log("AaveLendingAdapter", addrs.aaveAdapter);
        console2.log("AaveV4LendingAdapter", addrs.aaveV4Adapter);
        console2.log("MarginRouter", addrs.router);
        console2.log("Bootstrap governance (deployer)", deployer);
        if (finalGovernance != address(0) && finalGovernance != deployer) {
            console2.log("Proposed final governance (must acceptGovernance/acceptOwnership)", finalGovernance);
        }
        console2.log("Reset the deployer's 7702 delegation if the key is not throwaway.");
    }

    /// @notice The canonical markets to register, by chain. Mainnet mirrors the legacy DeployMargin
    ///         wiring (Morpho long ETH, Aave v3 + v4 short/long ETH); other chains register none and
    ///         are configured in a follow-up.
    function _markets()
        internal
        view
        returns (MarketParams[] memory morphoMarkets, AaveV3Market[] memory v3Markets, AaveV4Market[] memory v4Markets)
    {
        if (block.chainid != 1) {
            return (new MarketParams[](0), new AaveV3Market[](0), new AaveV4Market[](0));
        }

        morphoMarkets = new MarketParams[](1);
        morphoMarkets[0] = MarketParams({
            loanToken: MAINNET_USDC,
            collateralToken: MAINNET_WETH,
            oracle: MAINNET_MORPHO_WETH_USDC_ORACLE,
            irm: MAINNET_MORPHO_WETH_USDC_IRM,
            lltv: MAINNET_MORPHO_WETH_USDC_LLTV
        });

        v3Markets = new AaveV3Market[](2);
        v3Markets[0] = AaveV3Market({collateral: Currency.wrap(MAINNET_USDC), debt: Currency.wrap(MAINNET_WETH)});
        v3Markets[1] = AaveV3Market({collateral: Currency.wrap(MAINNET_WETH), debt: Currency.wrap(MAINNET_USDC)});

        v4Markets = new AaveV4Market[](2);
        v4Markets[0] = AaveV4Market({
            collateral: Currency.wrap(MAINNET_USDC),
            debt: Currency.wrap(MAINNET_WETH),
            collateralReserveId: MAINNET_AAVE_V4_USDC_RESERVE_ID,
            debtReserveId: MAINNET_AAVE_V4_WETH_RESERVE_ID
        });
        v4Markets[1] = AaveV4Market({
            collateral: Currency.wrap(MAINNET_WETH),
            debt: Currency.wrap(MAINNET_USDC),
            collateralReserveId: MAINNET_AAVE_V4_WETH_RESERVE_ID,
            debtReserveId: MAINNET_AAVE_V4_USDC_RESERVE_ID
        });
    }
}
