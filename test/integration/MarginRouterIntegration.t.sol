// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {RoutingTestHelpers} from "../shared/RoutingTestHelpers.sol";
import {MarginRouteHelpers} from "../shared/MarginRouteHelpers.sol";
import {DeployPermit2} from "permit2/test/utils/DeployPermit2.sol";
import {Vm} from "forge-std/Vm.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

import {IWETH9} from "../../src/interfaces/external/IWETH9.sol";
import {IMarginRouter} from "../../src/interfaces/IMarginRouter.sol";
import {MarginAccount} from "../../src/MarginAccount.sol";
import {Market} from "../../src/types/Market.sol";
import {Ltv, toLtv} from "../../src/types/Ltv.sol";
import {MockLendingAdapter} from "../mocks/MockLendingAdapter.sol";
import {MockLendingProtocol} from "../mocks/MockLendingProtocol.sol";

/// @notice End-to-end integration of the leverage flows against a real local PoolManager and pool,
///         with a mock lending protocol standing in for Morpho. Validates that the flash-style plan
///         assembly nets to zero and produces the expected position.
contract MarginRouterIntegrationTest is RoutingTestHelpers, MarginRouteHelpers, DeployPermit2 {
    IMarginRouter internal marginRouter;
    address internal ur;
    MockLendingAdapter internal adapter;
    MockLendingProtocol internal protocol;
    Market internal market;
    PoolKey internal poolKey;

    Currency internal collateral;
    Currency internal debt;

    /// @dev Mirrors the non-indexed data of `PositionIncreased` for single-variable log decoding.
    struct OpenedData {
        address collateral;
        address debt;
        uint256 equity;
        uint256 collateralBought;
        uint256 debtDrawn;
        uint256 collateralTotal;
        uint256 debtTotal;
        uint256 currentLtv;
        uint256 maxLtv;
        uint256 healthFactorWad;
    }

    function setUp() public {
        setupRouterCurrenciesAndPoolsWithLiquidity();

        collateral = currency0;
        debt = currency1;
        poolKey = key0; // (currency0, currency1) pool with deep 1:1 liquidity
        market = Market({collateral: collateral, debt: debt});

        protocol = new MockLendingProtocol(IERC20(Currency.unwrap(collateral)), IERC20(Currency.unwrap(debt)));
        adapter = new MockLendingAdapter(address(protocol));
        adapter.setSupported(market, true);

        address permit2 = deployPermit2();
        address impl = address(new MarginAccount());
        // route position swaps through a Universal Router bound to the local PoolManager
        ur = deployUniversalRouter(address(manager), permit2, address(0xbeef));
        marginRouter = IMarginRouter(
            deployMarginRouter(manager, IAllowanceTransfer(permit2), IWETH9(address(0xbeef)), impl, address(this))
        );
        marginRouter.setAdapterAllowed(adapter, true);

        // fund the lending protocol with debt to lend out
        MockERC20(Currency.unwrap(debt)).transfer(address(protocol), 1_000_000 ether);
    }

    function _open(uint256 equity, uint128 buy) internal returns (address account) {
        account = marginRouter.accountOf(address(this), 0);
        // provide equity directly to the account; equity=0 in params avoids the permit2 pull
        MockERC20(Currency.unwrap(collateral)).transfer(account, equity);
        (bytes memory cmds, bytes[] memory ins) = buildV4ExactOutRoute(poolKey, debt, collateral, buy, 5 ether, account);
        marginRouter.increasePosition(
            IMarginRouter.IncreaseParams({
                adapter: adapter,
                market: market,
                equity: 0,
                collateralToBuy: buy,
                maxDebtIn: 5 ether,
                universalRouter: ur,
                routeCommands: cmds,
                routeInputs: ins,
                maxLtvAfter: Ltv.wrap(0),
                subId: 0,
                deadline: block.timestamp + 1
            })
        );
    }

    function test_openLong_buildsLeveragedPosition() public {
        address account = _open(1 ether, 2 ether);
        vm.snapshotGasLastCall("MarginRouter_openLong");

        assertEq(protocol.collateralOf(account), 3 ether, "collateral = equity + bought");
        uint256 owed = protocol.debtOf(account);
        assertGt(owed, 0, "debt drawn");
        assertLe(owed, 5 ether, "debt within slippage bound");

        // nothing left loose in the account or the router
        assertEq(IERC20(Currency.unwrap(collateral)).balanceOf(account), 0, "account holds no loose collateral");
        assertEq(IERC20(Currency.unwrap(debt)).balanceOf(account), 0, "account holds no loose debt");
        assertEq(IERC20(Currency.unwrap(collateral)).balanceOf(address(marginRouter)), 0, "router holds no collateral");
        assertEq(IERC20(Currency.unwrap(debt)).balanceOf(address(marginRouter)), 0, "router holds no debt");
    }

    function test_openLong_revertsWhenResultingLtvExceedsBound() public {
        // fund equity directly, then open with a health bound below the mock's reported LTV (0.86)
        address account = marginRouter.accountOf(address(this), 0);
        MockERC20(Currency.unwrap(collateral)).transfer(account, 1 ether);
        (bytes memory cmds, bytes[] memory ins) =
            buildV4ExactOutRoute(poolKey, debt, collateral, 2 ether, 5 ether, account);
        vm.expectRevert(IMarginRouter.PositionUnhealthy.selector);
        marginRouter.increasePosition(
            IMarginRouter.IncreaseParams({
                adapter: adapter,
                market: market,
                equity: 0,
                collateralToBuy: 2 ether,
                maxDebtIn: 5 ether,
                universalRouter: ur,
                routeCommands: cmds,
                routeInputs: ins,
                maxLtvAfter: toLtv(0.5e18),
                subId: 0,
                deadline: block.timestamp + 1
            })
        );
    }

    function test_openLong_passesWhenLtvBoundSatisfied() public {
        // a bound at or above the reported LTV lets the open through (the check is a strict `>`)
        address account = marginRouter.accountOf(address(this), 0);
        MockERC20(Currency.unwrap(collateral)).transfer(account, 1 ether);
        (bytes memory cmds, bytes[] memory ins) =
            buildV4ExactOutRoute(poolKey, debt, collateral, 2 ether, 5 ether, account);
        marginRouter.increasePosition(
            IMarginRouter.IncreaseParams({
                adapter: adapter,
                market: market,
                equity: 0,
                collateralToBuy: 2 ether,
                maxDebtIn: 5 ether,
                universalRouter: ur,
                routeCommands: cmds,
                routeInputs: ins,
                maxLtvAfter: toLtv(0.86e18),
                subId: 0,
                deadline: block.timestamp + 1
            })
        );
        assertEq(protocol.collateralOf(account), 3 ether, "open succeeded within the health bound");
    }

    function test_closeLong_repaysAndReturnsResidual() public {
        address account = _open(1 ether, 2 ether);

        uint256 callerCollateralBefore = IERC20(Currency.unwrap(collateral)).balanceOf(address(this));

        (, uint256 curDebt) = adapter.positionOf(account, market);
        (bytes memory cmds, bytes[] memory ins) =
            buildV4ExactOutRoute(poolKey, collateral, debt, uint128(curDebt), 5 ether, account);
        marginRouter.decreasePosition(
            IMarginRouter.DecreaseParams({
                debtToRepay: type(uint256).max,
                maxLtvAfter: Ltv.wrap(0),
                adapter: adapter,
                market: market,
                maxCollateralIn: 5 ether,
                universalRouter: ur,
                routeCommands: cmds,
                routeInputs: ins,
                subId: 0,
                deadline: block.timestamp + 1
            })
        );
        vm.snapshotGasLastCall("MarginRouter_closeLong");

        assertEq(protocol.debtOf(account), 0, "debt fully repaid");
        assertEq(protocol.collateralOf(account), 0, "collateral fully withdrawn");
        assertGt(
            IERC20(Currency.unwrap(collateral)).balanceOf(address(this)),
            callerCollateralBefore,
            "residual collateral returned to caller"
        );
        assertEq(IERC20(Currency.unwrap(collateral)).balanceOf(address(marginRouter)), 0, "router holds no collateral");
        assertEq(IERC20(Currency.unwrap(debt)).balanceOf(address(marginRouter)), 0, "router holds no debt");
    }

    /// @dev addCollateral supplies directly (no unlock), so no action handler fires the snapshot;
    ///      the entry point must emit PositionUpdated inline with the full pair, or snapshot-only
    ///      indexers go stale on collateral top-ups and cannot attribute the supply to a market.
    function test_addCollateral_emitsPositionUpdatedSnapshot() public {
        address account = _open(1 ether, 2 ether);
        uint256 debtBefore = protocol.debtOf(account);

        // canonical Permit2 (DeployPermit2 etches it at the canonical address)
        IAllowanceTransfer permit2 = IAllowanceTransfer(0x000000000022D473030F116dDEE9F6B43aC78BA3);
        MockERC20(Currency.unwrap(collateral)).approve(address(permit2), type(uint256).max);
        permit2.approve(Currency.unwrap(collateral), address(marginRouter), type(uint160).max, type(uint48).max);

        vm.recordLogs();
        marginRouter.addCollateral(
            IMarginRouter.AddCollateralParams({
                adapter: adapter, market: market, amount: 0.5 ether, subId: 0, deadline: block.timestamp + 1
            })
        );
        Vm.Log[] memory logs = vm.getRecordedLogs();

        uint256 snapshotIndex = type(uint256).max;
        uint256 curatedIndex = type(uint256).max;
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter != address(marginRouter)) continue;
            if (logs[i].topics[0] == IMarginRouter.PositionUpdated.selector) {
                assertEq(snapshotIndex, type(uint256).max, "exactly one snapshot");
                snapshotIndex = i;
                assertEq(address(uint160(uint256(logs[i].topics[1]))), address(this), "owner topic");
                assertEq(address(uint160(uint256(logs[i].topics[2]))), account, "account topic");
                (address c, address d, uint256 collateralTotal, uint256 debtTotal,,,) =
                    abi.decode(logs[i].data, (address, address, uint256, uint256, uint256, uint256, uint256));
                assertEq(c, Currency.unwrap(collateral), "snapshot carries the collateral currency");
                assertEq(d, Currency.unwrap(debt), "snapshot carries the debt currency");
                assertEq(collateralTotal, 3.5 ether, "collateralTotal reflects the top-up");
                assertEq(debtTotal, debtBefore, "debt untouched by the top-up");
            } else if (logs[i].topics[0] == IMarginRouter.CollateralAdded.selector) {
                curatedIndex = i;
            }
        }
        assertTrue(snapshotIndex != type(uint256).max, "PositionUpdated emitted");
        assertTrue(curatedIndex != type(uint256).max, "CollateralAdded emitted");
        assertLt(snapshotIndex, curatedIndex, "snapshot precedes the curated event, as on the unlock paths");
    }

    function test_close_zeroDebt_returnsCollateral() public {
        address account = _open(1 ether, 2 ether);
        // the position holds collateral supplied during the open
        assertEq(protocol.collateralOf(account), 3 ether, "collateral supplied");

        // simulate the debt being cleared out of band (e.g. repaid directly or fully liquidated),
        // leaving collateral but no debt
        protocol.setDebt(account, 0);

        uint256 callerBefore = IERC20(Currency.unwrap(collateral)).balanceOf(address(this));

        // a zero-debt close takes the swap-free path: collateral is withdrawn straight to the caller
        // zero-debt full close takes the swap-free path and ignores the route
        marginRouter.decreasePosition(
            IMarginRouter.DecreaseParams({
                debtToRepay: type(uint256).max,
                maxLtvAfter: Ltv.wrap(0),
                adapter: adapter,
                market: market,
                maxCollateralIn: 0, // no swap, so no slippage bound is required
                universalRouter: ur,
                routeCommands: "",
                routeInputs: new bytes[](0),
                subId: 0,
                deadline: block.timestamp + 1
            })
        );

        assertEq(
            IERC20(Currency.unwrap(collateral)).balanceOf(address(this)) - callerBefore,
            3 ether,
            "collateral returned to caller"
        );
        assertEq(protocol.collateralOf(account), 0, "collateral fully withdrawn");
        assertEq(protocol.debtOf(account), 0, "position empty");
        assertEq(IERC20(Currency.unwrap(collateral)).balanceOf(address(marginRouter)), 0, "router holds no collateral");
    }

    /// @dev The zero-debt full close bypasses the unlock interpreter, so the entry point must emit
    ///      the terminal PositionUpdated itself; without it a snapshot-only indexer never sees the
    ///      position close.
    function test_close_zeroDebt_emitsTerminalPositionUpdatedSnapshot() public {
        address account = _open(1 ether, 2 ether);
        protocol.setDebt(account, 0);

        vm.recordLogs();
        marginRouter.decreasePosition(
            IMarginRouter.DecreaseParams({
                debtToRepay: type(uint256).max,
                maxLtvAfter: Ltv.wrap(0),
                adapter: adapter,
                market: market,
                maxCollateralIn: 0,
                universalRouter: ur,
                routeCommands: "",
                routeInputs: new bytes[](0),
                subId: 0,
                deadline: block.timestamp + 1
            })
        );
        Vm.Log[] memory logs = vm.getRecordedLogs();

        uint256 count;
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter != address(marginRouter)) continue;
            if (logs[i].topics[0] != IMarginRouter.PositionUpdated.selector) continue;
            count++;
            assertEq(address(uint160(uint256(logs[i].topics[1]))), address(this), "owner topic");
            assertEq(address(uint160(uint256(logs[i].topics[2]))), account, "account topic");
            (address c, address d, uint256 collateralTotal, uint256 debtTotal, uint256 currentLtv,, uint256 hf) =
                abi.decode(logs[i].data, (address, address, uint256, uint256, uint256, uint256, uint256));
            assertEq(c, Currency.unwrap(collateral), "collateral currency");
            assertEq(d, Currency.unwrap(debt), "debt currency");
            assertEq(collateralTotal, 0, "terminal snapshot: no collateral");
            assertEq(debtTotal, 0, "terminal snapshot: no debt");
            assertEq(currentLtv, 0, "terminal snapshot: zero LTV");
            assertEq(hf, type(uint256).max, "terminal snapshot: debt-free health factor");
        }
        assertEq(count, 1, "exactly one terminal snapshot");
    }

    function test_closeLong_doesNotSweepDonatedBalance() public {
        address account = _open(1 ether, 2 ether);

        // a stray balance lands on the router (e.g. a donation or dust from another flow)
        uint256 donation = 0.5 ether;
        MockERC20(Currency.unwrap(collateral)).transfer(address(marginRouter), donation);

        uint256 callerBefore = IERC20(Currency.unwrap(collateral)).balanceOf(address(this));

        (, uint256 curDebt) = adapter.positionOf(account, market);
        (bytes memory cmds, bytes[] memory ins) =
            buildV4ExactOutRoute(poolKey, collateral, debt, uint128(curDebt), 5 ether, account);
        marginRouter.decreasePosition(
            IMarginRouter.DecreaseParams({
                debtToRepay: type(uint256).max,
                maxLtvAfter: Ltv.wrap(0),
                adapter: adapter,
                market: market,
                maxCollateralIn: 5 ether,
                universalRouter: ur,
                routeCommands: cmds,
                routeInputs: ins,
                subId: 0,
                deadline: block.timestamp + 1
            })
        );

        // the caller receives only their own realized residual; the donation stays in the router.
        // this is a property of the curated close (it measures its own collateral delta and forwards
        // exactly that), NOT a global router invariant: an `execute` plan can SWEEP a router balance,
        // and any residual left by a plan is claimable by the next caller (see MarginRouterExecute).
        uint256 callerGain = IERC20(Currency.unwrap(collateral)).balanceOf(address(this)) - callerBefore;
        assertGt(callerGain, 0, "caller receives their own residual");
        assertEq(
            IERC20(Currency.unwrap(collateral)).balanceOf(address(marginRouter)),
            donation,
            "donated balance is left in the router by the curated close, not swept to the caller"
        );
        assertEq(protocol.debtOf(account), 0, "debt fully repaid");
        assertEq(protocol.collateralOf(account), 0, "collateral fully withdrawn");
    }

    function test_closeLong_succeedsAfterAdapterDeAllowlisted() public {
        address account = _open(1 ether, 2 ether);

        // governance removes the adapter from the allowlist while the position is still open
        marginRouter.setAdapterAllowed(adapter, false);
        assertFalse(marginRouter.isAdapterAllowed(adapter), "adapter de-allowlisted");

        // the position can still be unwound: the allowlist only gates exposure-increasing operations
        (, uint256 curDebt) = adapter.positionOf(account, market);
        (bytes memory cmds, bytes[] memory ins) =
            buildV4ExactOutRoute(poolKey, collateral, debt, uint128(curDebt), 5 ether, account);
        marginRouter.decreasePosition(
            IMarginRouter.DecreaseParams({
                debtToRepay: type(uint256).max,
                maxLtvAfter: Ltv.wrap(0),
                adapter: adapter,
                market: market,
                maxCollateralIn: 5 ether,
                universalRouter: ur,
                routeCommands: cmds,
                routeInputs: ins,
                subId: 0,
                deadline: block.timestamp + 1
            })
        );

        assertEq(protocol.debtOf(account), 0, "debt fully repaid");
        assertEq(protocol.collateralOf(account), 0, "collateral fully withdrawn");
    }

    function test_decreasePosition_succeedsAfterAdapterDeAllowlisted() public {
        address account = _open(1 ether, 2 ether);
        uint256 debtAfterOpen = protocol.debtOf(account);

        marginRouter.setAdapterAllowed(adapter, false);

        // delevering an open position still works once the adapter is de-allowlisted
        (bytes memory cmds, bytes[] memory ins) =
            buildV4ExactOutRoute(poolKey, collateral, debt, 1 ether, 2 ether, account);
        marginRouter.decreasePosition(
            IMarginRouter.DecreaseParams({
                adapter: adapter,
                market: market,
                debtToRepay: 1 ether,
                maxCollateralIn: 2 ether,
                universalRouter: ur,
                routeCommands: cmds,
                routeInputs: ins,
                maxLtvAfter: toLtv(0.9e18),
                subId: 0,
                deadline: block.timestamp + 1
            })
        );

        assertLt(protocol.debtOf(account), debtAfterOpen, "debt reduced");
        assertGt(protocol.debtOf(account), 0, "position still open");
    }

    function test_openLong_emitsPositionIncreased() public {
        address account = marginRouter.accountOf(address(this), 0);
        MockERC20(Currency.unwrap(collateral)).transfer(account, 1 ether);

        // decode the emitted event rather than predict the pool-dependent debt: the enriched fields
        // carry full resulting state so an indexer needs no follow-up RPC
        (bytes memory cmds, bytes[] memory ins) =
            buildV4ExactOutRoute(poolKey, debt, collateral, 2 ether, 5 ether, account);
        vm.recordLogs();
        marginRouter.increasePosition(
            IMarginRouter.IncreaseParams({
                adapter: adapter,
                market: market,
                equity: 0,
                collateralToBuy: 2 ether,
                maxDebtIn: 5 ether,
                universalRouter: ur,
                routeCommands: cmds,
                routeInputs: ins,
                maxLtvAfter: Ltv.wrap(0),
                subId: 0,
                deadline: block.timestamp + 1
            })
        );

        uint256 debtOwed = protocol.debtOf(account);
        bytes32 topic0 = keccak256(
            "PositionIncreased(address,address,address,address,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256)"
        );
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool found;
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter != address(marginRouter) || logs[i].topics[0] != topic0) continue;
            found = true;
            assertEq(address(uint160(uint256(logs[i].topics[1]))), address(this), "owner topic");
            assertEq(address(uint160(uint256(logs[i].topics[2]))), account, "account topic");
            OpenedData memory od = abi.decode(logs[i].data, (OpenedData));
            assertEq(od.collateral, Currency.unwrap(collateral), "collateral");
            assertEq(od.debt, Currency.unwrap(debt), "debt");
            assertEq(od.equity, 0, "equity is router-pulled only (pre-funded here)");
            assertEq(od.collateralBought, 2 ether, "collateralBought");
            assertEq(od.debtDrawn, debtOwed, "debtDrawn equals resulting debt on a fresh open");
            assertEq(od.collateralTotal, 3 ether, "collateralTotal = equity + bought");
            assertEq(od.debtTotal, debtOwed, "debtTotal");
            uint256 expectedLtv = od.debtTotal * 1e18 / od.collateralTotal;
            assertEq(od.currentLtv, expectedLtv, "currentLtv (mock reports the ledger ratio)");
            assertEq(od.maxLtv, 0.86e18, "maxLtv (mock)");
            assertEq(od.healthFactorWad, 0.86e18 * 1e18 / expectedLtv, "healthFactor == maxLtv / currentLtv");
        }
        assertTrue(found, "PositionIncreased emitted");
    }

    function test_increasePosition_addsLeverageToExistingPosition() public {
        address account = _open(1 ether, 2 ether);
        uint256 debtAfterOpen = protocol.debtOf(account);

        // a second open into the same account adds leverage to the existing position
        (bytes memory cmds, bytes[] memory ins) =
            buildV4ExactOutRoute(poolKey, debt, collateral, 1 ether, 3 ether, account);
        marginRouter.increasePosition(
            IMarginRouter.IncreaseParams({
                adapter: adapter,
                market: market,
                equity: 0,
                collateralToBuy: 1 ether,
                maxDebtIn: 3 ether,
                universalRouter: ur,
                routeCommands: cmds,
                routeInputs: ins,
                maxLtvAfter: Ltv.wrap(0),
                subId: 0,
                deadline: block.timestamp + 1
            })
        );
        vm.snapshotGasLastCall("MarginRouter_increasePosition_addLeverage");

        assertEq(protocol.collateralOf(account), 4 ether, "collateral grew by the bought amount");
        assertGt(protocol.debtOf(account), debtAfterOpen, "debt grew");
    }

    function test_decreasePosition_delevers() public {
        address account = _open(1 ether, 2 ether);
        uint256 debtAfterOpen = protocol.debtOf(account);
        uint256 collateralAfterOpen = protocol.collateralOf(account);

        (bytes memory cmds, bytes[] memory ins) =
            buildV4ExactOutRoute(poolKey, collateral, debt, 1 ether, 2 ether, account);
        marginRouter.decreasePosition(
            IMarginRouter.DecreaseParams({
                adapter: adapter,
                market: market,
                debtToRepay: 1 ether,
                maxCollateralIn: 2 ether,
                universalRouter: ur,
                routeCommands: cmds,
                routeInputs: ins,
                maxLtvAfter: toLtv(0.9e18),
                subId: 0,
                deadline: block.timestamp + 1
            })
        );
        vm.snapshotGasLastCall("MarginRouter_decreasePosition");

        assertLt(protocol.debtOf(account), debtAfterOpen, "debt reduced");
        assertGt(protocol.debtOf(account), 0, "position still open");
        assertLt(protocol.collateralOf(account), collateralAfterOpen, "collateral reduced");
        assertGt(protocol.collateralOf(account), 0, "collateral remains");
    }

    function test_decreasePosition_revertsWhenResultingLtvTooHigh() public {
        address account = _open(1 ether, 2 ether);
        (bytes memory cmds, bytes[] memory ins) =
            buildV4ExactOutRoute(poolKey, collateral, debt, 1 ether, 2 ether, account);
        vm.expectRevert(IMarginRouter.PositionUnhealthy.selector);
        marginRouter.decreasePosition(
            IMarginRouter.DecreaseParams({
                adapter: adapter,
                market: market,
                debtToRepay: 1 ether,
                maxCollateralIn: 2 ether,
                universalRouter: ur,
                routeCommands: cmds,
                routeInputs: ins,
                maxLtvAfter: toLtv(0.5e18),
                subId: 0,
                deadline: block.timestamp + 1
            })
        );
    }
}
