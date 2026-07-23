// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {RoutingTestHelpers} from "../shared/RoutingTestHelpers.sol";
import {Plan, Planner} from "../shared/Planner.sol";
import {DeployPermit2} from "permit2/test/utils/DeployPermit2.sol";
import {Vm} from "forge-std/Vm.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

import {IWETH9} from "../../src/interfaces/external/IWETH9.sol";
import {MarginRouter} from "../../src/MarginRouter.sol";
import {IMarginRouter} from "../../src/interfaces/IMarginRouter.sol";
import {MarginAccount} from "../../src/MarginAccount.sol";
import {IMarginAccount} from "../../src/interfaces/IMarginAccount.sol";
import {IV4Router} from "../../src/interfaces/IV4Router.sol";
import {Actions} from "../../src/libraries/Actions.sol";
import {MarginActions} from "../../src/libraries/MarginActions.sol";
import {ActionConstants} from "../../src/libraries/ActionConstants.sol";
import {BaseActionsRouter} from "../../src/base/BaseActionsRouter.sol";
import {ReentrancyLock} from "../../src/base/ReentrancyLock.sol";
import {Market} from "../../src/types/Market.sol";
import {Ltv, toLtv} from "../../src/types/Ltv.sol";
import {MockLendingAdapter} from "../mocks/MockLendingAdapter.sol";
import {MockLendingProtocol} from "../mocks/MockLendingProtocol.sol";

/// @notice Integration tests for the generalized `execute` entrypoint against a real local
///         PoolManager and pool, with a mock lending protocol standing in for Morpho. Covers
///         parity with the curated flows, the new opcodes (SET_ACCOUNT, PULL_TO_ACCOUNT, and the
///         intercepted SWEEP), the handler-level guards, and the security-relevant behaviors from
///         the design review (caller-scoped accounts, allowlist asymmetry, residual claimability).
contract MarginRouterExecuteTest is RoutingTestHelpers, DeployPermit2 {
    using Planner for Plan;

    MarginRouter internal marginRouter;
    MockLendingAdapter internal adapter;
    MockLendingProtocol internal protocol;
    IAllowanceTransfer internal permit2;
    Market internal market;
    PoolKey internal poolKey;
    Currency internal collateral;
    Currency internal debt;

    function setUp() public {
        setupRouterCurrenciesAndPoolsWithLiquidity();
        permit2 = IAllowanceTransfer(deployPermit2());

        collateral = currency0;
        debt = currency1;
        poolKey = key0; // (currency0, currency1) pool with deep 1:1 liquidity
        market = Market({collateral: collateral, debt: debt});

        protocol = new MockLendingProtocol(IERC20(Currency.unwrap(collateral)), IERC20(Currency.unwrap(debt)));
        adapter = new MockLendingAdapter(address(protocol));
        adapter.setSupported(market, true);

        address impl = address(new MarginAccount());
        marginRouter = new MarginRouter(manager, permit2, IWETH9(address(0xbeef)), impl, address(this));
        marginRouter.setAdapterAllowed(adapter, true);

        // fund the lending protocol with debt to lend out
        MockERC20(Currency.unwrap(debt)).transfer(address(protocol), 1_000_000 ether);

        // authorize the router as a Permit2 spender for both tokens (PULL_TO_ACCOUNT and settle)
        MockERC20(Currency.unwrap(collateral)).approve(address(permit2), type(uint256).max);
        MockERC20(Currency.unwrap(debt)).approve(address(permit2), type(uint256).max);
        permit2.approve(Currency.unwrap(collateral), address(marginRouter), type(uint160).max, type(uint48).max);
        permit2.approve(Currency.unwrap(debt), address(marginRouter), type(uint160).max, type(uint48).max);
    }

    // ─────────────────────────────────────── Plan builders ──────────────────────────────────────

    /// @dev Build the execute-equivalent of a curated open: SET_ACCOUNT, buy collateral
    ///      exact-output, assert the fill, take it to the account, supply, borrow the owed debt to
    ///      the router, settle. Equity is pre-funded to the account by the caller (like the curated
    ///      integration harness), so `equity == 0` in the plan.
    function _openPlan(uint256 subId, uint128 buy, uint128 maxDebtIn) internal view returns (bytes memory) {
        address account = marginRouter.accountOf(address(this), subId);
        bool zeroForOne = market.toSwapParams(market.debt, 0, 0, poolKey).zeroForOne;

        Plan memory plan = Planner.init();
        plan = plan.add(MarginActions.SET_ACCOUNT, abi.encode(subId));
        plan = plan.add(
            Actions.SWAP_EXACT_OUT_SINGLE,
            abi.encode(
                IV4Router.ExactOutputSingleParams({
                    poolKey: poolKey,
                    zeroForOne: zeroForOne,
                    amountOut: buy,
                    amountInMaximum: maxDebtIn,
                    minHopPriceX36: 0,
                    hookData: ""
                })
            )
        );
        plan = plan.add(MarginActions.ASSERT_FILL, abi.encode(collateral, uint256(buy)));
        plan = plan.add(Actions.TAKE, abi.encode(collateral, account, ActionConstants.OPEN_DELTA));
        plan =
            plan.add(MarginActions.ACCOUNT_SUPPLY_COLLATERAL, abi.encode(adapter, market, ActionConstants.OPEN_DELTA));
        plan = plan.add(
            MarginActions.ACCOUNT_BORROW, abi.encode(adapter, market, ActionConstants.OPEN_DELTA, address(marginRouter))
        );
        plan = plan.add(Actions.SETTLE, abi.encode(debt, ActionConstants.OPEN_DELTA, false));
        return plan.encode();
    }

    /// @dev Open a position through `execute` for `subId`, pre-funding `equity` collateral to the
    ///      account first (matching the curated integration harness's `_open`).
    function _openViaExecute(uint256 subId, uint256 equity, uint128 buy) internal returns (address account) {
        account = marginRouter.accountOf(address(this), subId);
        MockERC20(Currency.unwrap(collateral)).transfer(account, equity);
        marginRouter.execute(_openPlan(subId, buy, 5 ether), block.timestamp + 1);
    }

    // ─────────────────────────────────────────── Parity ─────────────────────────────────────────

    function test_execute_open_buildsLeveragedPosition() public {
        address account = _openViaExecute(0, 1 ether, 2 ether);
        vm.snapshotGasLastCall("MarginRouter_execute_open");

        assertEq(protocol.collateralOf(account), 3 ether, "collateral = equity + bought");
        uint256 owed = protocol.debtOf(account);
        assertGt(owed, 0, "debt drawn");
        assertLe(owed, 5 ether, "debt within slippage bound");
        _assertNoResidual(account);
    }

    function test_execute_open_matchesCuratedState() public {
        // both opens must run from identical pool state; a sequential second open would swap at a
        // price the first one moved, so snapshot and revert between them
        uint256 snap = vm.snapshotState();

        // curated open on subId 0
        address account = marginRouter.accountOf(address(this), 0);
        MockERC20(Currency.unwrap(collateral)).transfer(account, 1 ether);
        marginRouter.increasePosition(
            IMarginRouter.IncreaseParams({
                adapter: adapter,
                market: market,
                poolKey: poolKey,
                equity: 0,
                collateralToBuy: 2 ether,
                maxDebtIn: 5 ether,
                minHopPriceX36: 0,
                maxLtvAfter: Ltv.wrap(0),
                subId: 0,
                deadline: block.timestamp + 1
            })
        );
        uint256 curatedCollateral = protocol.collateralOf(account);
        uint256 curatedDebt = protocol.debtOf(account);

        vm.revertToState(snap);

        // execute-built open on subId 0 from the identical starting state, identical inputs
        address executeAccount = _openViaExecute(0, 1 ether, 2 ether);

        assertEq(protocol.collateralOf(executeAccount), curatedCollateral, "collateral parity");
        assertEq(protocol.debtOf(executeAccount), curatedDebt, "debt parity");
    }

    function test_execute_fullClose_withSweep_returnsResidual() public {
        address account = _openViaExecute(0, 1 ether, 2 ether);
        uint256 debtOwed = protocol.debtOf(account);
        uint256 collateralHeld = protocol.collateralOf(account);
        bool zeroForOne = market.toSwapParams(market.collateral, 0, 0, poolKey).zeroForOne;

        uint256 callerBefore = IERC20(Currency.unwrap(collateral)).balanceOf(address(this));

        // buy the whole debt exact-output, repay all by shares, withdraw all collateral, settle the
        // swap from the router, then SWEEP the realized residual to the caller
        Plan memory plan = Planner.init();
        plan = plan.add(MarginActions.SET_ACCOUNT, abi.encode(uint256(0)));
        plan = plan.add(
            Actions.SWAP_EXACT_OUT_SINGLE,
            abi.encode(
                IV4Router.ExactOutputSingleParams({
                    poolKey: poolKey,
                    zeroForOne: zeroForOne,
                    amountOut: uint128(debtOwed),
                    amountInMaximum: 5 ether,
                    minHopPriceX36: 0,
                    hookData: ""
                })
            )
        );
        plan = plan.add(Actions.TAKE, abi.encode(debt, account, ActionConstants.OPEN_DELTA));
        plan = plan.add(MarginActions.ACCOUNT_REPAY, abi.encode(adapter, market, type(uint256).max));
        plan = plan.add(
            MarginActions.ACCOUNT_WITHDRAW_COLLATERAL,
            abi.encode(adapter, market, collateralHeld, address(marginRouter))
        );
        plan = plan.add(Actions.SETTLE, abi.encode(collateral, ActionConstants.OPEN_DELTA, false));
        plan = plan.add(Actions.SWEEP, abi.encode(collateral, ActionConstants.MSG_SENDER));
        marginRouter.execute(plan.encode(), block.timestamp + 1);
        vm.snapshotGasLastCall("MarginRouter_execute_close");

        assertEq(protocol.debtOf(account), 0, "debt fully repaid");
        assertEq(protocol.collateralOf(account), 0, "collateral fully withdrawn");
        assertGt(
            IERC20(Currency.unwrap(collateral)).balanceOf(address(this)),
            callerBefore,
            "realized residual swept to caller"
        );
        _assertNoResidual(account);
    }

    // ─────────────────────────────────────── NoActiveAccount ────────────────────────────────────

    function test_execute_revertsNoActiveAccount_whenSetAccountOmitted() public {
        // a supply action with no preceding SET_ACCOUNT has no active account
        Plan memory plan = Planner.init();
        plan = plan.add(MarginActions.ACCOUNT_SUPPLY_COLLATERAL, abi.encode(adapter, market, uint256(1 ether)));
        vm.expectRevert(IMarginRouter.NoActiveAccount.selector);
        marginRouter.execute(plan.encode(), block.timestamp + 1);
    }

    function test_execute_revertsNoActiveAccount_forPullWithoutSetAccount() public {
        Plan memory plan = Planner.init();
        plan = plan.add(MarginActions.PULL_TO_ACCOUNT, abi.encode(collateral, uint256(1 ether), true));
        vm.expectRevert(IMarginRouter.NoActiveAccount.selector);
        marginRouter.execute(plan.encode(), block.timestamp + 1);
    }

    function test_execute_revertsNoActiveAccount_forEveryAccountScopedOpcode() public {
        // one bare op per account-scoped opcode, each with no preceding SET_ACCOUNT: the shared
        // guard must trip for all of them, not just the two above
        _expectNoActiveAccount(
            MarginActions.ACCOUNT_WITHDRAW_COLLATERAL, abi.encode(adapter, market, uint256(1), address(this))
        );
        _expectNoActiveAccount(MarginActions.ACCOUNT_BORROW, abi.encode(adapter, market, uint256(1), address(this)));
        _expectNoActiveAccount(MarginActions.ACCOUNT_REPAY, abi.encode(adapter, market, uint256(1)));
        _expectNoActiveAccount(MarginActions.ACCOUNT_SWEEP, abi.encode(collateral, uint256(1), address(this)));
        _expectNoActiveAccount(MarginActions.ASSERT_HEALTH, abi.encode(adapter, market, toLtv(0.5e18)));
    }

    function _expectNoActiveAccount(uint256 action, bytes memory params) internal {
        Plan memory plan = Planner.init();
        plan = plan.add(action, params);
        vm.expectRevert(IMarginRouter.NoActiveAccount.selector);
        marginRouter.execute(plan.encode(), block.timestamp + 1);
    }

    function test_execute_multicall_clearsActiveAccountBetweenLegs() public {
        // leg 1 sets an account and no-ops; leg 2 has a bare account-scoped op with no SET_ACCOUNT.
        // execute clears the transient slot after each call, so leg 2 must see no active account and
        // revert NoActiveAccount. This pins that the _setActiveAccount(0) at the end of execute is
        // load-bearing: transient storage persists across multicall's self-delegatecalls otherwise.
        Plan memory legA = Planner.init();
        legA = legA.add(MarginActions.SET_ACCOUNT, abi.encode(uint256(0)));
        legA = legA.add(MarginActions.ACCOUNT_SWEEP, abi.encode(collateral, uint256(0), address(this)));

        Plan memory legB = Planner.init();
        legB = legB.add(MarginActions.ACCOUNT_SWEEP, abi.encode(collateral, uint256(0), address(this)));

        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeCall(MarginRouter.execute, (legA.encode(), block.timestamp + 1));
        calls[1] = abi.encodeCall(MarginRouter.execute, (legB.encode(), block.timestamp + 1));

        vm.expectRevert(IMarginRouter.NoActiveAccount.selector);
        marginRouter.multicall(calls);
    }

    // ─────────────────────────────────────── Health / reentrancy ────────────────────────────────

    function test_execute_assertHealth_revertsWhenBoundExceeded() public {
        address account = _openViaExecute(0, 1 ether, 2 ether);
        // the mock reports currentLtv == maxLtv == 0.86e18; a 0.5 bound must trip PositionUnhealthy
        Plan memory plan = Planner.init();
        plan = plan.add(MarginActions.SET_ACCOUNT, abi.encode(uint256(0)));
        plan = plan.add(MarginActions.ASSERT_HEALTH, abi.encode(adapter, market, toLtv(0.5e18)));
        vm.expectRevert(IMarginRouter.PositionUnhealthy.selector);
        marginRouter.execute(plan.encode(), block.timestamp + 1);
    }

    function test_execute_assertHealth_passesWhenBoundSatisfied() public {
        address account = _openViaExecute(0, 1 ether, 2 ether);
        // a bound at the reported LTV passes (the check is a strict `>` overflow)
        Plan memory plan = Planner.init();
        plan = plan.add(MarginActions.SET_ACCOUNT, abi.encode(uint256(0)));
        plan = plan.add(MarginActions.ASSERT_HEALTH, abi.encode(adapter, market, toLtv(0.86e18)));
        marginRouter.execute(plan.encode(), block.timestamp + 1);
        assertGt(protocol.collateralOf(account), 0, "position unchanged by a passing health assert");
    }

    function test_execute_pullToAccount_contractBalanceRevertsForUserPayer() public {
        // CONTRACT_BALANCE (1<<255) is not honored on the Permit2 path: it overflows the uint160
        // cast, so the router-balance sentinel can never be smuggled onto the caller's allowance
        _openViaExecute(0, 1 ether, 2 ether);
        Plan memory plan = Planner.init();
        plan = plan.add(MarginActions.SET_ACCOUNT, abi.encode(uint256(0)));
        plan = plan.add(MarginActions.PULL_TO_ACCOUNT, abi.encode(collateral, ActionConstants.CONTRACT_BALANCE, true));
        vm.expectRevert(SafeCast.SafeCastOverflow.selector);
        marginRouter.execute(plan.encode(), block.timestamp + 1);
    }

    function test_execute_revertsOnReentrancy_viaMaliciousProtocol() public {
        // a lending protocol that reenters the router during supply must be stopped by isNotLocked.
        // wire a fresh adapter at the reentrant protocol, allowlist it, fund an account, and supply.
        ReentrantLendingProtocol evil = new ReentrantLendingProtocol(marginRouter);
        MockLendingAdapter evilAdapter = new MockLendingAdapter(address(evil));
        evilAdapter.setSupported(market, true);
        marginRouter.setAdapterAllowed(evilAdapter, true);

        address account = marginRouter.accountOf(address(this), 0);
        MockERC20(Currency.unwrap(collateral)).transfer(account, 1 ether);

        Plan memory plan = Planner.init();
        plan = plan.add(MarginActions.SET_ACCOUNT, abi.encode(uint256(0)));
        plan = plan.add(
            MarginActions.ACCOUNT_SUPPLY_COLLATERAL, abi.encode(evilAdapter, market, ActionConstants.OPEN_DELTA)
        );

        // the reentrant execute call inside supply hits isNotLocked and bubbles ContractLocked out
        vm.expectRevert(ReentrancyLock.ContractLocked.selector);
        marginRouter.execute(plan.encode(), block.timestamp + 1);
    }

    // ─────────────────────────────────────── Allowlist asymmetry ────────────────────────────────

    function test_execute_supply_revertsWhenAdapterNotAllowed() public {
        marginRouter.setAdapterAllowed(adapter, false);
        address account = marginRouter.accountOf(address(this), 0);
        MockERC20(Currency.unwrap(collateral)).transfer(account, 1 ether);

        Plan memory plan = Planner.init();
        plan = plan.add(MarginActions.SET_ACCOUNT, abi.encode(uint256(0)));
        plan =
            plan.add(MarginActions.ACCOUNT_SUPPLY_COLLATERAL, abi.encode(adapter, market, ActionConstants.OPEN_DELTA));
        vm.expectRevert(abi.encodeWithSelector(IMarginRouter.AdapterNotAllowed.selector, address(adapter)));
        marginRouter.execute(plan.encode(), block.timestamp + 1);
    }

    function test_execute_borrow_revertsWhenAdapterNotAllowed() public {
        // open while allowed, then de-allowlist and try to draw more debt via execute
        address account = _openViaExecute(0, 1 ether, 2 ether);
        marginRouter.setAdapterAllowed(adapter, false);

        Plan memory plan = Planner.init();
        plan = plan.add(MarginActions.SET_ACCOUNT, abi.encode(uint256(0)));
        plan = plan.add(MarginActions.ACCOUNT_BORROW, abi.encode(adapter, market, uint256(1), address(marginRouter)));
        vm.expectRevert(abi.encodeWithSelector(IMarginRouter.AdapterNotAllowed.selector, address(adapter)));
        marginRouter.execute(plan.encode(), block.timestamp + 1);
        account; // position untouched; the guard reverts before the borrow
    }

    function test_execute_exit_succeedsAfterAdapterDeAllowlisted() public {
        address account = _openViaExecute(0, 1 ether, 2 ether);
        uint256 debtOwed = protocol.debtOf(account);
        uint256 collateralHeld = protocol.collateralOf(account);

        // governance removes the adapter; the exit path (repay + withdraw) must still work
        marginRouter.setAdapterAllowed(adapter, false);

        // fund the repay from the wallet via Permit2 so no swap/allowlisted-borrow is needed
        bytes memory plan = _exitPlanRepayFromWallet(0, debtOwed, collateralHeld);
        marginRouter.execute(plan, block.timestamp + 1);

        assertEq(protocol.debtOf(account), 0, "debt repaid despite de-allowlisting");
        assertEq(protocol.collateralOf(account), 0, "collateral withdrawn despite de-allowlisting");
    }

    /// @dev Exit plan that repays from the caller's wallet (Permit2) rather than by selling
    ///      collateral: pull debt in, repay all, withdraw all collateral to the caller. Uses none
    ///      of the allowlist-gated opcodes.
    function _exitPlanRepayFromWallet(uint256 subId, uint256 debtOwed, uint256 collateralHeld)
        internal
        view
        returns (bytes memory)
    {
        Plan memory plan = Planner.init();
        plan = plan.add(MarginActions.SET_ACCOUNT, abi.encode(subId));
        plan = plan.add(MarginActions.PULL_TO_ACCOUNT, abi.encode(debt, debtOwed, true));
        plan = plan.add(MarginActions.ACCOUNT_REPAY, abi.encode(adapter, market, type(uint256).max));
        plan = plan.add(
            MarginActions.ACCOUNT_WITHDRAW_COLLATERAL, abi.encode(adapter, market, collateralHeld, address(this))
        );
        return plan.encode();
    }

    // ─────────────────────────────────────── SET_ACCOUNT scoping ────────────────────────────────

    function test_execute_setAccount_isScopedToCaller() public {
        address attacker = makeAddr("attacker");
        // victim opens a position on their own account
        address victimAccount = _openViaExecute(0, 1 ether, 2 ether);
        uint256 victimCollateral = protocol.collateralOf(victimAccount);
        uint256 victimDebt = protocol.debtOf(victimAccount);

        // attacker runs a plan; SET_ACCOUNT(0) resolves to the ATTACKER's own account, not the
        // victim's, because it is derived from msgSender()
        address attackerAccount = marginRouter.accountOf(attacker, 0);
        assertTrue(attackerAccount != victimAccount, "distinct accounts");

        Plan memory plan = Planner.init();
        plan = plan.add(MarginActions.SET_ACCOUNT, abi.encode(uint256(0)));
        // a harmless account-sweep of nothing; the point is which account it binds
        plan = plan.add(MarginActions.ACCOUNT_SWEEP, abi.encode(collateral, uint256(0), attacker));
        vm.prank(attacker);
        marginRouter.execute(plan.encode(), block.timestamp + 1);

        // victim untouched
        assertEq(protocol.collateralOf(victimAccount), victimCollateral, "victim collateral untouched");
        assertEq(protocol.debtOf(victimAccount), victimDebt, "victim debt untouched");
    }

    function test_execute_cannotDrainAnotherUsersAccount() public {
        address attacker = makeAddr("attacker");
        // victim opens a real, funded position on subId 0
        address victimAccount = _openViaExecute(0, 1 ether, 2 ether);
        uint256 victimCollateral = protocol.collateralOf(victimAccount);
        uint256 victimDebt = protocol.debtOf(victimAccount);
        assertGt(victimCollateral, 0, "victim is funded");

        // the attacker's only lever is subId; there is no account-address field in a plan. A plan
        // that tries to withdraw the victim's collateral to the attacker binds accountOf(attacker, 0)
        // — the attacker's own empty account (the receiver check even allows `attacker`, since they
        // own it) — so the withdrawal underflows the empty position and reverts. The victim's funds
        // are never reachable.
        Plan memory plan = Planner.init();
        plan = plan.add(MarginActions.SET_ACCOUNT, abi.encode(uint256(0)));
        plan = plan.add(
            MarginActions.ACCOUNT_WITHDRAW_COLLATERAL, abi.encode(adapter, market, victimCollateral, attacker)
        );

        vm.prank(attacker);
        vm.expectRevert(); // arithmetic underflow: the attacker's own account holds no collateral
        marginRouter.execute(plan.encode(), block.timestamp + 1);

        // the victim's position is fully intact and the attacker received nothing
        assertEq(protocol.collateralOf(victimAccount), victimCollateral, "victim collateral intact");
        assertEq(protocol.debtOf(victimAccount), victimDebt, "victim debt intact");
        assertEq(IERC20(Currency.unwrap(collateral)).balanceOf(attacker), 0, "attacker gained no collateral");
    }

    function test_execute_setAccount_deploysFreshAccount_emitsAccountCreated() public {
        uint256 freshSubId = 42;
        address predicted = marginRouter.accountOf(address(this), freshSubId);
        assertEq(predicted.code.length, 0, "account not yet deployed");

        Plan memory plan = Planner.init();
        plan = plan.add(MarginActions.SET_ACCOUNT, abi.encode(freshSubId));
        plan = plan.add(MarginActions.ACCOUNT_SWEEP, abi.encode(collateral, uint256(0), address(this)));

        vm.recordLogs();
        marginRouter.execute(plan.encode(), block.timestamp + 1);

        assertGt(predicted.code.length, 0, "account deployed inside the unlock");
        bytes32 topic0 = keccak256("AccountCreated(address,address,uint256)");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool found;
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].topics[0] != topic0) continue;
            found = true;
        }
        assertTrue(found, "AccountCreated emitted for the fresh sub-account");
    }

    function test_execute_migratesCollateralBetweenSubAccounts() public {
        // open on subId 0, then move a slice of its collateral to subId 1 in one plan:
        // withdraw from A to the router, pull it into B, supply on B.
        address accountA = _openViaExecute(0, 1 ether, 2 ether);
        address accountB = marginRouter.accountOf(address(this), 1);
        uint256 moved = 0.5 ether;

        Plan memory plan = Planner.init();
        plan = plan.add(MarginActions.SET_ACCOUNT, abi.encode(uint256(0)));
        plan = plan.add(
            MarginActions.ACCOUNT_WITHDRAW_COLLATERAL, abi.encode(adapter, market, moved, address(marginRouter))
        );
        plan = plan.add(MarginActions.SET_ACCOUNT, abi.encode(uint256(1)));
        plan = plan.add(MarginActions.PULL_TO_ACCOUNT, abi.encode(collateral, moved, false));
        plan =
            plan.add(MarginActions.ACCOUNT_SUPPLY_COLLATERAL, abi.encode(adapter, market, ActionConstants.OPEN_DELTA));
        marginRouter.execute(plan.encode(), block.timestamp + 1);

        assertEq(protocol.collateralOf(accountA), 3 ether - moved, "A collateral reduced by moved");
        assertEq(protocol.collateralOf(accountB), moved, "B collateral increased by moved");
        _assertNoResidual(accountA);
        _assertNoResidual(accountB);
    }

    // ─────────────────────────────────────── PULL_TO_ACCOUNT ────────────────────────────────────

    function test_execute_pullToAccount_zeroReverts_userPayer() public {
        _openViaExecute(0, 1 ether, 2 ether);
        Plan memory plan = Planner.init();
        plan = plan.add(MarginActions.SET_ACCOUNT, abi.encode(uint256(0)));
        plan = plan.add(MarginActions.PULL_TO_ACCOUNT, abi.encode(debt, uint256(0), true));
        vm.expectRevert(IMarginRouter.SlippageBoundRequired.selector);
        marginRouter.execute(plan.encode(), block.timestamp + 1);
    }

    function test_execute_pullToAccount_zeroReverts_routerPayer() public {
        _openViaExecute(0, 1 ether, 2 ether);
        Plan memory plan = Planner.init();
        plan = plan.add(MarginActions.SET_ACCOUNT, abi.encode(uint256(0)));
        plan = plan.add(MarginActions.PULL_TO_ACCOUNT, abi.encode(collateral, uint256(0), false));
        vm.expectRevert(IMarginRouter.SlippageBoundRequired.selector);
        marginRouter.execute(plan.encode(), block.timestamp + 1);
    }

    function test_execute_pullToAccount_repayFromWallet() public {
        address account = _openViaExecute(0, 1 ether, 2 ether);
        uint256 debtOwed = protocol.debtOf(account);

        // repay entirely from the caller's wallet via Permit2, no collateral sold
        Plan memory plan = Planner.init();
        plan = plan.add(MarginActions.SET_ACCOUNT, abi.encode(uint256(0)));
        plan = plan.add(MarginActions.PULL_TO_ACCOUNT, abi.encode(debt, debtOwed, true));
        plan = plan.add(MarginActions.ACCOUNT_REPAY, abi.encode(adapter, market, type(uint256).max));
        marginRouter.execute(plan.encode(), block.timestamp + 1);
        vm.snapshotGasLastCall("MarginRouter_execute_repayFromWallet");

        assertEq(protocol.debtOf(account), 0, "debt repaid from wallet");
        assertEq(protocol.collateralOf(account), 3 ether, "collateral untouched");
        _assertNoResidual(account);
    }

    // ─────────────────────────────────────── Residual model ─────────────────────────────────────

    function test_execute_residualIsClaimableByNextCaller() public {
        // a plan that leaves collateral on the router (a builder error: no terminating SWEEP)
        address account = marginRouter.accountOf(address(this), 0);
        MockERC20(Currency.unwrap(collateral)).transfer(account, 1 ether);
        // withdraw is a no-op source of router funds here; instead directly simulate a residual by
        // pulling caller funds to the router via a plan that forgets to sweep
        Plan memory strand = Planner.init();
        strand = strand.add(MarginActions.SET_ACCOUNT, abi.encode(uint256(0)));
        // pull 1 ether of collateral from the wallet into the account, then sweep it OUT of the
        // account to the router, leaving it stranded there
        strand = strand.add(MarginActions.PULL_TO_ACCOUNT, abi.encode(collateral, uint256(1 ether), true));
        strand =
            strand.add(MarginActions.ACCOUNT_SWEEP, abi.encode(collateral, uint256(1 ether), address(marginRouter)));
        marginRouter.execute(strand.encode(), block.timestamp + 1);
        assertEq(
            IERC20(Currency.unwrap(collateral)).balanceOf(address(marginRouter)),
            1 ether,
            "collateral stranded on router"
        );

        // an unrelated caller claims the stranded balance with a bare SWEEP
        address claimer = makeAddr("claimer");
        Plan memory claim = Planner.init();
        claim = claim.add(Actions.SWEEP, abi.encode(collateral, claimer));
        vm.prank(claimer);
        marginRouter.execute(claim.encode(), block.timestamp + 1);

        assertEq(IERC20(Currency.unwrap(collateral)).balanceOf(claimer), 1 ether, "next caller claimed the residual");
        assertEq(IERC20(Currency.unwrap(collateral)).balanceOf(address(marginRouter)), 0, "router drained");
        account; // silence unused warning
    }

    // ─────────────────────────────────────── Misc guards ────────────────────────────────────────

    function test_execute_revertsWhenDeadlinePassed() public {
        Plan memory plan = Planner.init();
        plan = plan.add(MarginActions.SET_ACCOUNT, abi.encode(uint256(0)));
        vm.warp(1000);
        vm.expectRevert(abi.encodeWithSelector(IMarginRouter.DeadlinePassed.selector, uint256(999)));
        marginRouter.execute(plan.encode(), 999);
    }

    function test_execute_revertsOnUnsupportedAction() public {
        // 0x39 is above the highest margin opcode (PULL_TO_ACCOUNT 0x38) and unhandled. SET_ACCOUNT
        // first so it passes the NoActiveAccount guard and reaches the trailing UnsupportedAction.
        Plan memory plan = Planner.init();
        plan = plan.add(MarginActions.SET_ACCOUNT, abi.encode(uint256(0)));
        plan = plan.add(0x39, "");
        vm.expectRevert(abi.encodeWithSelector(BaseActionsRouter.UnsupportedAction.selector, 0x39));
        marginRouter.execute(plan.encode(), block.timestamp + 1);
    }

    function test_execute_revertsOnReservedGapOpcode() public {
        // 0x1c sits in the reserved gap: below the margin range, above the inherited Actions space,
        // and not one of the intercepted SWEEP/WRAP/UNWRAP, so V4Router rejects it
        Plan memory plan = Planner.init();
        plan = plan.add(0x1c, "");
        vm.expectRevert(abi.encodeWithSelector(BaseActionsRouter.UnsupportedAction.selector, 0x1c));
        marginRouter.execute(plan.encode(), block.timestamp + 1);
    }

    function test_execute_doesNotEmitPositionEvents() public {
        address account = marginRouter.accountOf(address(this), 0);
        MockERC20(Currency.unwrap(collateral)).transfer(account, 1 ether);

        vm.recordLogs();
        marginRouter.execute(_openPlan(0, 2 ether, 5 ether), block.timestamp + 1);

        bytes32 positionIncreased = keccak256(
            "PositionIncreased(address,address,address,address,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256)"
        );
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; i++) {
            assertTrue(logs[i].topics[0] != positionIncreased, "execute must not emit Position* snapshots");
        }
    }

    // ───────────────────────────────────────── Helpers ──────────────────────────────────────────

    function _assertNoResidual(address account) internal view {
        assertEq(IERC20(Currency.unwrap(collateral)).balanceOf(account), 0, "account holds no loose collateral");
        assertEq(IERC20(Currency.unwrap(debt)).balanceOf(account), 0, "account holds no loose debt");
        assertEq(IERC20(Currency.unwrap(collateral)).balanceOf(address(marginRouter)), 0, "router holds no collateral");
        assertEq(IERC20(Currency.unwrap(debt)).balanceOf(address(marginRouter)), 0, "router holds no debt");
    }
}

/// @notice A lending protocol stand-in that reenters the router during `supplyCollateral`. Used to
///         prove the `isNotLocked` guard on `execute` stops reentrancy through a malicious protocol
///         reached mid-plan.
contract ReentrantLendingProtocol {
    MarginRouter internal immutable router;

    constructor(MarginRouter router_) {
        router = router_;
    }

    /// @dev Called by the MarginAccount during the supply leg; reenter the still-locked router.
    ///      The empty plan is never decoded: `isNotLocked` reverts before the body runs.
    function supplyCollateral(address, uint256) external {
        router.execute("", block.timestamp + 1);
    }
}
