// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {MarketParams} from "morpho-blue/interfaces/IMorpho.sol";

import {BatchExecutor} from "../../script/BatchExecutor.sol";
import {MarginBootstrapBuilder} from "../../script/MarginBootstrapBuilder.sol";
import {MarginRouter} from "../../src/MarginRouter.sol";
import {MorphoLendingAdapter} from "../../src/MorphoLendingAdapter.sol";
import {AaveLendingAdapter} from "../../src/AaveLendingAdapter.sol";
import {AaveV4LendingAdapter} from "../../src/AaveV4LendingAdapter.sol";
import {CompoundV3LendingAdapter} from "../../src/CompoundV3LendingAdapter.sol";
import {ILendingAdapter} from "../../src/interfaces/ILendingAdapter.sol";
import {Market} from "../../src/types/Market.sol";

import {MarginRouteHelpers} from "../shared/MarginRouteHelpers.sol";

/// @notice Mainnet-fork simulation of the single-transaction EIP-7702 bootstrap using the mined
///         router salt. The deployer EOA's delegation to the BatchExecutor is modeled with vm.etch
///         (the code that a 7702 authorization would install on the account), and the batch is driven
///         as a self-call. Proves the whole stack deploys and wires against the LIVE Morpho / Aave v3
///         / Aave v4 / PoolManager in one call, and that the router lands at the mined vanity address.
contract MarginBootstrap7702ForkTest is Test, MarginRouteHelpers {
    // mainnet addresses (verified in the per-adapter fork tests)
    address internal constant POOL_MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    address internal constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address internal constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address internal constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address internal constant UNI = 0x1f9840a85d5aF5bf1D1762F925BDADdC4201F984;
    address internal constant MORPHO = 0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb;
    address internal constant AAVE_V3_PROVIDER = 0x2f39d218133AFaB8F2B819B1066c7E434Ad94E9e;
    address internal constant AAVE_V4_SPOKE = 0x94e7A5dCbE816e498b89aB752661904E2F56c485;
    address internal constant COMET_USDC = 0xc3d688B66703497DAA19211EEdff47f25384cdc3;

    // Morpho WETH/USDC market (long ETH), verified on-chain by MorphoLendingAdapter.fork
    address internal constant MORPHO_WETH_USDC_ORACLE = 0xdC6fd5831277c693b1054e19E94047cB37c77615;
    address internal constant MORPHO_WETH_USDC_IRM = 0x870aC11D48B15DB9a138Cf899d20F13F79Ba00BC;
    uint256 internal constant MORPHO_WETH_USDC_LLTV = 0.86e18;
    // Aave v4 Main Spoke reserve ids
    uint256 internal constant AAVE_V4_WETH_RESERVE_ID = 0;
    uint256 internal constant AAVE_V4_USDC_RESERVE_ID = 7;

    // the established deployer/governance from the prior mainnet deploy; the mined salt is bound to it
    address internal constant DEPLOYER = 0x58e28b95a2ee57c4E90613AFce9e8CCEED3aB1E8;
    // the mined router salt and the vanity address it must produce
    bytes32 internal constant ROUTER_SALT = 0x000000000000000000000000000000000000000065698c3cb5e73630b1c0cc10;
    address internal constant EXPECTED_ROUTER = 0x0000000666Adc6Ecc1A344fDB78F369B64F84444;
    // CREATE2_FACTORY (0x4e59...) is inherited from forge-std Test.
    // MarginRouter init-code hash under the DEPLOY build profile (via_ir=true), the salt was mined
    // against this. Foundry compiles test/** with via_ir=false (see foundry.toml
    // compilation_restrictions), so the router bytecode this test builds differs from the deploy's;
    // the vanity therefore holds under the deploy profile, verified statically below, while the flow
    // below runs on the test-profile bytecode.
    bytes32 internal constant DEPLOY_INIT_CODE_HASH =
        0x68356c43185b048cf8d445baf37fafebbf62de39172d70ea417df19ead24d6fc;

    uint256 internal constant FORK_BLOCK = 25_330_047;

    BatchExecutor internal executor;
    MarginBootstrapBuilder internal builder;
    // a Universal Router bound to the live PoolManager; the router requires a non-zero UR at
    // construction, and this test asserts deploy/wiring rather than routing a curated swap
    address internal universalRouter;

    function setUp() public {
        string memory rpc = vm.envOr("MAINNET_RPC_URL", string(""));
        vm.skip(bytes(rpc).length == 0);
        if (bytes(rpc).length == 0) return;
        vm.createSelectFork(rpc, FORK_BLOCK);

        executor = new BatchExecutor();
        builder = new MarginBootstrapBuilder();
        universalRouter = deployUniversalRouter(POOL_MANAGER, PERMIT2, WETH);
    }

    function test_fork_bootstrap_oneTx_landsVanityAndWiresStack() public {
        address finalGovernance = makeAddr("multisig");

        // the mined salt yields the vanity address under the deploy build profile (this is what the
        // forge-script deploy uses); verified statically since this test compiles the router differently
        assertEq(
            vm.computeCreate2Address(ROUTER_SALT, DEPLOY_INIT_CODE_HASH, CREATE2_FACTORY),
            EXPECTED_ROUTER,
            "salt yields the vanity router under the deploy (via_ir) profile"
        );

        (BatchExecutor.Call[] memory calls, MarginBootstrapBuilder.Deployed memory addrs) =
            builder.buildPlan(_deps(), DEPLOYER, ROUTER_SALT, _markets(), finalGovernance);

        // model the EIP-7702 delegation: install the executor's code on the deployer EOA, then the
        // deployer self-calls execute() with the whole deploy-and-bootstrap batch (one transaction)
        vm.etch(DEPLOYER, address(executor).code);
        vm.prank(DEPLOYER);
        BatchExecutor(payable(DEPLOYER)).execute(calls);

        // everything deployed at the predicted addresses (test-profile bytecode)
        assertGt(addrs.router.code.length, 0, "router deployed");
        assertGt(addrs.impl.code.length, 0, "impl deployed");
        assertGt(addrs.morphoAdapter.code.length, 0, "morpho adapter deployed");
        assertGt(addrs.aaveAdapter.code.length, 0, "aave v3 adapter deployed");
        assertGt(addrs.aaveV4Adapter.code.length, 0, "aave v4 adapter deployed");
        assertGt(addrs.compoundAdapter.code.length, 0, "compound adapter deployed");

        MarginRouter router = MarginRouter(payable(addrs.router));
        // adapters allowlisted, impl and governance set, handoff proposed
        assertTrue(router.isAdapterAllowed(ILendingAdapter(addrs.morphoAdapter)), "morpho allowlisted");
        assertTrue(router.isAdapterAllowed(ILendingAdapter(addrs.aaveAdapter)), "aave v3 allowlisted");
        assertTrue(router.isAdapterAllowed(ILendingAdapter(addrs.aaveV4Adapter)), "aave v4 allowlisted");
        assertTrue(router.isAdapterAllowed(ILendingAdapter(addrs.compoundAdapter)), "compound allowlisted");
        assertEq(router.accountImplementation(), addrs.impl, "router uses the deployed impl");
        assertEq(router.governance(), DEPLOYER, "bootstrap governance is the deployer");
        assertEq(router.pendingGovernance(), finalGovernance, "final governance proposed (two-step handoff)");

        // markets registered against the live protocols
        assertTrue(
            MorphoLendingAdapter(addrs.morphoAdapter)
                .isSupportedMarket(Market({collateral: Currency.wrap(WETH), debt: Currency.wrap(USDC)})),
            "morpho long-ETH market registered"
        );
        assertTrue(
            AaveLendingAdapter(addrs.aaveAdapter)
                .isSupportedMarket(Market({collateral: Currency.wrap(USDC), debt: Currency.wrap(WETH)})),
            "aave v3 short-ETH market registered"
        );
        assertTrue(
            AaveV4LendingAdapter(addrs.aaveV4Adapter)
                .isSupportedMarket(Market({collateral: Currency.wrap(USDC), debt: Currency.wrap(WETH)})),
            "aave v4 short-ETH market registered"
        );
        assertTrue(
            CompoundV3LendingAdapter(addrs.compoundAdapter)
                .isSupportedMarket(Market({collateral: Currency.wrap(UNI), debt: Currency.wrap(USDC)})),
            "compound long-UNI market registered"
        );

        // adapters owned by the deployer with the handoff proposed
        assertEq(MorphoLendingAdapter(addrs.morphoAdapter).owner(), DEPLOYER, "morpho adapter owner");
        assertEq(MorphoLendingAdapter(addrs.morphoAdapter).pendingOwner(), finalGovernance, "morpho adapter handoff");
    }

    function _deps() internal view returns (MarginBootstrapBuilder.Deps memory) {
        return MarginBootstrapBuilder.Deps({
            poolManager: POOL_MANAGER,
            permit2: PERMIT2,
            weth9: WETH,
            morpho: MORPHO,
            aaveProvider: AAVE_V3_PROVIDER,
            aaveV4Spoke: AAVE_V4_SPOKE,
            compoundComet: COMET_USDC,
            universalRouter: universalRouter
        });
    }

    function _markets() internal pure returns (MarginBootstrapBuilder.Markets memory m) {
        m.morpho = new MarketParams[](1);
        m.morpho[0] = MarketParams({
            loanToken: USDC,
            collateralToken: WETH,
            oracle: MORPHO_WETH_USDC_ORACLE,
            irm: MORPHO_WETH_USDC_IRM,
            lltv: MORPHO_WETH_USDC_LLTV
        });

        m.v3 = new MarginBootstrapBuilder.AaveV3Market[](2);
        m.v3[0] = MarginBootstrapBuilder.AaveV3Market({collateral: Currency.wrap(USDC), debt: Currency.wrap(WETH)});
        m.v3[1] = MarginBootstrapBuilder.AaveV3Market({collateral: Currency.wrap(WETH), debt: Currency.wrap(USDC)});

        m.v4 = new MarginBootstrapBuilder.AaveV4Market[](2);
        m.v4[0] = MarginBootstrapBuilder.AaveV4Market({
            collateral: Currency.wrap(USDC),
            debt: Currency.wrap(WETH),
            collateralReserveId: AAVE_V4_USDC_RESERVE_ID,
            debtReserveId: AAVE_V4_WETH_RESERVE_ID
        });
        m.v4[1] = MarginBootstrapBuilder.AaveV4Market({
            collateral: Currency.wrap(WETH),
            debt: Currency.wrap(USDC),
            collateralReserveId: AAVE_V4_WETH_RESERVE_ID,
            debtReserveId: AAVE_V4_USDC_RESERVE_ID
        });

        m.compound = new MarginBootstrapBuilder.CompoundMarket[](1);
        m.compound[0] =
            MarginBootstrapBuilder.CompoundMarket({collateral: Currency.wrap(UNI), debt: Currency.wrap(USDC)});
    }
}
