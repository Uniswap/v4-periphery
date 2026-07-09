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
import {ILendingAdapter} from "../../src/interfaces/ILendingAdapter.sol";
import {Market} from "../../src/types/Market.sol";

import {MockMorpho} from "../mocks/MockMorpho.sol";
import {MockAavePool, MockAaveAddressesProvider, MockAaveDataProvider} from "../mocks/MockAavePool.sol";
import {MockAaveV4Spoke} from "../mocks/MockAaveV4Spoke.sol";

/// @notice Proves the whole margin stack deploys and bootstraps in a single EIP-7702 transaction: the
///         deployer EOA delegates to the BatchExecutor and, in one self-call, deploys the account
///         implementation, all three adapters, and the router through the standard CREATE2 factory,
///         then allowlists the adapters and registers a market. Also covers the two-step handoff.
contract MarginBootstrap7702Test is Test {
    BatchExecutor internal executor;
    MarginBootstrapBuilder internal builder;

    MockMorpho internal morpho;
    MockAaveAddressesProvider internal aaveProvider;
    MockAaveV4Spoke internal aaveV4Spoke;

    // deployer / bootstrap governance
    uint256 internal deployerPk = 0xA11CE;
    address internal deployer;

    address internal poolManager = makeAddr("poolManager");
    address internal permit2 = makeAddr("permit2");
    address internal weth9 = makeAddr("weth9");

    // a Morpho market to register; tokens/oracle/irm are placeholders (the mock only needs it to exist)
    address internal collateralToken = makeAddr("collateralToken");
    address internal loanToken = makeAddr("loanToken");
    MarketParams internal mp;
    Market internal market;

    bytes32 internal constant ROUTER_SALT = bytes32(uint256(0x4242));

    function setUp() public {
        deployer = vm.addr(deployerPk);

        executor = new BatchExecutor();
        builder = new MarginBootstrapBuilder();

        morpho = new MockMorpho();
        MockAavePool pool = new MockAavePool();
        MockAaveDataProvider dp = new MockAaveDataProvider(pool);
        aaveProvider = new MockAaveAddressesProvider(address(pool), address(dp));
        aaveV4Spoke = new MockAaveV4Spoke(makeAddr("v4Oracle"));

        mp = MarketParams({
            loanToken: loanToken,
            collateralToken: collateralToken,
            oracle: makeAddr("oracle"),
            irm: makeAddr("irm"),
            lltv: 0.86e18
        });
        morpho.setMarketParams(mp); // make the market "exist" so MorphoLendingAdapter.setMarket accepts it
        market = Market({collateral: Currency.wrap(collateralToken), debt: Currency.wrap(loanToken)});

        // the standard CREATE2 factory must be present for the batch's deploys
        assertGt(CREATE2_FACTORY.code.length, 0, "CREATE2 factory missing from test EVM");
    }

    function _deps() internal view returns (MarginBootstrapBuilder.Deps memory) {
        return MarginBootstrapBuilder.Deps({
            poolManager: poolManager,
            permit2: permit2,
            weth9: weth9,
            morpho: address(morpho),
            aaveProvider: address(aaveProvider),
            aaveV4Spoke: address(aaveV4Spoke)
        });
    }

    function _morphoMarkets() internal view returns (MarketParams[] memory m) {
        m = new MarketParams[](1);
        m[0] = mp;
    }

    function test_bootstrap_deploysAndWiresEntireStackInOneTx() public {
        (BatchExecutor.Call[] memory calls, MarginBootstrapBuilder.Deployed memory addrs) = builder.buildPlan(
            _deps(),
            deployer, // bootstrap governance
            ROUTER_SALT,
            _morphoMarkets(),
            new MarginBootstrapBuilder.AaveV3Market[](0),
            new MarginBootstrapBuilder.AaveV4Market[](0),
            deployer // no handoff (finalGovernance == governance)
        );

        // one transaction: delegate the EOA to the executor and self-call execute()
        vm.signAndAttachDelegation(address(executor), deployerPk);
        vm.prank(deployer);
        BatchExecutor(payable(deployer)).execute(calls);

        // everything is deployed at the addresses the builder predicted (and the miner would produce)
        assertGt(addrs.router.code.length, 0, "router deployed");
        assertGt(addrs.impl.code.length, 0, "impl deployed");
        assertGt(addrs.morphoAdapter.code.length, 0, "morpho adapter deployed");
        assertGt(addrs.aaveAdapter.code.length, 0, "aave v3 adapter deployed");
        assertGt(addrs.aaveV4Adapter.code.length, 0, "aave v4 adapter deployed");

        MarginRouter router = MarginRouter(payable(addrs.router));
        // wired: adapters allowlisted, impl and governance set, market registered
        assertTrue(router.isAdapterAllowed(ILendingAdapter(addrs.morphoAdapter)), "morpho allowlisted");
        assertTrue(router.isAdapterAllowed(ILendingAdapter(addrs.aaveAdapter)), "aave v3 allowlisted");
        assertTrue(router.isAdapterAllowed(ILendingAdapter(addrs.aaveV4Adapter)), "aave v4 allowlisted");
        assertEq(router.accountImplementation(), addrs.impl, "router uses deployed impl");
        assertEq(router.governance(), deployer, "bootstrap governance is the deployer");
        assertTrue(MorphoLendingAdapter(addrs.morphoAdapter).isSupportedMarket(market), "morpho market registered");
        assertEq(MorphoLendingAdapter(addrs.morphoAdapter).owner(), deployer, "morpho adapter owned by deployer");
    }

    function test_bootstrap_withHandoff_proposesFinalGovernanceAtomically() public {
        address finalGovernance = makeAddr("multisig");

        (BatchExecutor.Call[] memory calls, MarginBootstrapBuilder.Deployed memory addrs) = builder.buildPlan(
            _deps(),
            deployer,
            ROUTER_SALT,
            _morphoMarkets(),
            new MarginBootstrapBuilder.AaveV3Market[](0),
            new MarginBootstrapBuilder.AaveV4Market[](0),
            finalGovernance
        );

        vm.signAndAttachDelegation(address(executor), deployerPk);
        vm.prank(deployer);
        BatchExecutor(payable(deployer)).execute(calls);

        MarginRouter router = MarginRouter(payable(addrs.router));
        MorphoLendingAdapter morphoAdapter = MorphoLendingAdapter(addrs.morphoAdapter);

        // two-step handoff: proposed but not yet effective (recipient must accept)
        assertEq(router.governance(), deployer, "governance still deployer until accepted");
        assertEq(router.pendingGovernance(), finalGovernance, "final governance proposed");
        assertEq(morphoAdapter.owner(), deployer, "adapter owner still deployer");
        assertEq(morphoAdapter.pendingOwner(), finalGovernance, "adapter owner proposed");

        // recipient completes the handoff
        vm.prank(finalGovernance);
        router.acceptGovernance();
        assertEq(router.governance(), finalGovernance, "governance handed off");

        vm.prank(finalGovernance);
        morphoAdapter.acceptOwnership();
        assertEq(morphoAdapter.owner(), finalGovernance, "adapter ownership handed off");
    }

    function test_execute_revertsForThirdPartyCaller() public {
        (BatchExecutor.Call[] memory calls,) = builder.buildPlan(
            _deps(),
            deployer,
            ROUTER_SALT,
            _morphoMarkets(),
            new MarginBootstrapBuilder.AaveV3Market[](0),
            new MarginBootstrapBuilder.AaveV4Market[](0),
            deployer
        );
        vm.signAndAttachDelegation(address(executor), deployerPk);
        // a caller other than the account itself cannot drive the delegated code
        vm.prank(makeAddr("attacker"));
        vm.expectRevert(BatchExecutor.Unauthorized.selector);
        BatchExecutor(payable(deployer)).execute(calls);
    }
}
