// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {RoutingTestHelpers} from "../shared/RoutingTestHelpers.sol";
import {MarginRouteHelpers} from "../shared/MarginRouteHelpers.sol";
import {Plan, Planner} from "../shared/Planner.sol";
import {DeployPermit2} from "permit2/test/utils/DeployPermit2.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {Commands} from "universal-router/contracts/libraries/Commands.sol";

import {IWETH9} from "../../src/interfaces/external/IWETH9.sol";
import {IMarginRouter} from "../../src/interfaces/IMarginRouter.sol";
import {IV4Router} from "../../src/interfaces/IV4Router.sol";
import {MarginAccount} from "../../src/MarginAccount.sol";
import {Actions} from "../../src/libraries/Actions.sol";
import {ActionConstants} from "../../src/libraries/ActionConstants.sol";
import {MarginActions} from "../../src/libraries/MarginActions.sol";
import {Market} from "../../src/types/Market.sol";
import {Ltv} from "../../src/types/Ltv.sol";
import {MockLendingAdapter} from "../mocks/MockLendingAdapter.sol";
import {MockLendingProtocol} from "../mocks/MockLendingProtocol.sol";

/// @notice `ROUTE_SWAP` spend accounting. The router measures what a route spent as what Permit2
///         pulled from it, credits input that came back (to the router, or to the active account and
///         swept back) against that spend, and settles the rest of its flash-take. These tests drive
///         the shapes that used to mis-account: a pre-funded Universal Router whose balance is swept
///         back to the router, and a default-custody exact-output route (the whole cap is pulled into
///         the Universal Router, the swap settles from its balance, and the unspent remainder is swept
///         to the account) on both an increase and a full close.
contract MarginRouterRouteSpendTest is RoutingTestHelpers, MarginRouteHelpers, DeployPermit2 {
    using Planner for Plan;

    uint128 internal constant MAX_IN = 5 ether;
    uint128 internal constant BUY = 2 ether;

    IMarginRouter internal marginRouter;
    IAllowanceTransfer internal permit2;
    address internal ur;
    MockLendingAdapter internal adapter;
    MockLendingProtocol internal protocol;
    Market internal market;
    PoolKey internal poolKey;

    Currency internal collateral;
    Currency internal debt;

    function setUp() public {
        setupRouterCurrenciesAndPoolsWithLiquidity();

        collateral = currency0;
        debt = currency1;
        poolKey = key0;
        market = Market({collateral: collateral, debt: debt, data: ""});

        protocol = new MockLendingProtocol(IERC20(Currency.unwrap(collateral)), IERC20(Currency.unwrap(debt)));
        adapter = new MockLendingAdapter(address(protocol));
        adapter.setSupported(market, true);

        permit2 = IAllowanceTransfer(deployPermit2());
        address impl = address(new MarginAccount());
        ur = deployUniversalRouter(address(manager), address(permit2), address(0xbeef));
        marginRouter = IMarginRouter(deployMarginRouter(manager, permit2, IWETH9(address(0xbeef)), impl));

        MockERC20(Currency.unwrap(debt)).transfer(address(protocol), 1_000_000 ether);
    }

    // ─────────────────────────────────────────── Helpers ────────────────────────────────────────

    /// @dev The default-custody exact-output route: pull the whole cap into the Universal Router,
    ///      settle the v4 swap from its balance, take the output to `outputTo`, and sweep whatever is
    ///      left of the input to `changeTo`.
    function _custodyRoute(
        Currency input,
        Currency output,
        uint128 amountOut,
        uint128 maxIn,
        address outputTo,
        address changeTo
    ) internal view returns (bytes memory commands, bytes[] memory inputs) {
        bytes memory v4Actions = abi.encodePacked(
            uint8(Actions.SWAP_EXACT_OUT_SINGLE), uint8(Actions.SETTLE), uint8(Actions.TAKE)
        );
        bytes[] memory v4Params = new bytes[](3);
        v4Params[0] = abi.encode(
            IV4Router.ExactOutputSingleParams({
                poolKey: poolKey,
                zeroForOne: Currency.unwrap(input) == Currency.unwrap(poolKey.currency0),
                amountOut: amountOut,
                amountInMaximum: maxIn,
                minHopPriceX36: 0,
                hookData: ""
            })
        );
        // pay the pool from the Universal Router's own balance
        v4Params[1] = abi.encode(input, uint256(ActionConstants.OPEN_DELTA), false);
        v4Params[2] = abi.encode(output, outputTo, uint256(ActionConstants.OPEN_DELTA));

        commands =
            abi.encodePacked(uint8(Commands.PERMIT2_TRANSFER_FROM), uint8(Commands.V4_SWAP), uint8(Commands.SWEEP));
        inputs = new bytes[](3);
        inputs[0] = abi.encode(Currency.unwrap(input), ActionConstants.ADDRESS_THIS, uint160(maxIn));
        inputs[1] = abi.encode(v4Actions, v4Params);
        inputs[2] = abi.encode(Currency.unwrap(input), changeTo, uint256(0));
    }

    /// @dev The documented route (pull from the router straight into the pool) with a whole-balance
    ///      sweep of the input back to the router appended.
    function _sweepSuffixedRoute(address recipient)
        internal
        view
        returns (bytes memory commands, bytes[] memory inputs)
    {
        (bytes memory baseCommands, bytes[] memory baseInputs) = buildV4ExactOutRoute(
            poolKey, debt, collateral, BUY, MAX_IN, recipient
        );
        commands = abi.encodePacked(baseCommands, uint8(Commands.SWEEP));
        inputs = new bytes[](2);
        inputs[0] = baseInputs[0];
        inputs[1] = abi.encode(Currency.unwrap(debt), ActionConstants.MSG_SENDER, uint256(0));
    }

    function _increase(uint256 subId, bytes memory commands, bytes[] memory inputs) internal returns (address account) {
        account = marginRouter.accountOf(address(this), subId);
        MockERC20(Currency.unwrap(collateral)).transfer(account, 1 ether);
        marginRouter.increasePosition(
            IMarginRouter.IncreaseParams({
                adapter: adapter,
                market: market,
                equity: 0,
                collateralToBuy: BUY,
                maxDebtIn: MAX_IN,
                universalRouter: ur,
                routeCommands: commands,
                routeInputs: inputs,
                maxLtvAfter: Ltv.wrap(0),
                subId: subId,
                deadline: block.timestamp + 1
            })
        );
    }

    function _balance(Currency currency, address who) internal view returns (uint256) {
        return IERC20(Currency.unwrap(currency)).balanceOf(who);
    }

    // ───────────────────────────── Change returned to the router or the account ────────────────────

    /// @notice The route sends its change to the router (`MSG_SENDER`): the position borrows only the
    ///         actual cost, not the cap.
    function test_increase_changeToRouter_borrowsActualCost() public {
        address account = marginRouter.accountOf(address(this), 0);
        (bytes memory cmds, bytes[] memory ins) =
            _custodyRoute(debt, collateral, BUY, MAX_IN, account, ActionConstants.MSG_SENDER);
        _increase(0, cmds, ins);

        uint256 owed = protocol.debtOf(account);
        assertGe(owed, BUY, "debt covers the purchase");
        assertLt(owed, MAX_IN, "debt is the actual cost, not the cap");
        assertEq(_balance(debt, account), 0, "no idle change in the account");
        assertEq(_balance(debt, address(marginRouter)), 0, "router nets to zero");
        assertEq(_balance(debt, ur), 0, "Universal Router holds nothing");
    }

    /// @notice The route sends its change to the account (the universal-router-sdk default for a
    ///         recipient-delivered trade). The router sweeps the in-route rise back and settles it, so
    ///         the position borrows the actual cost, same as the router-change shape.
    function test_increase_changeToAccount_isRepatriated() public {
        address routerChange = marginRouter.accountOf(address(this), 0);
        (bytes memory cmdsA, bytes[] memory insA) =
            _custodyRoute(debt, collateral, BUY, MAX_IN, routerChange, ActionConstants.MSG_SENDER);
        _increase(0, cmdsA, insA);

        address account = marginRouter.accountOf(address(this), 1);
        (bytes memory cmds, bytes[] memory ins) = _custodyRoute(debt, collateral, BUY, MAX_IN, account, account);
        _increase(1, cmds, ins);

        uint256 owed = protocol.debtOf(account);
        assertLt(owed, MAX_IN, "the refund reduced the borrow below the cap");
        assertApproxEqRel(owed, protocol.debtOf(routerChange), 0.05e18, "same cost as the router-change shape");
        assertEq(_balance(debt, account), 0, "the change did not stay idle in the account");
        assertEq(_balance(debt, address(marginRouter)), 0, "router nets to zero");
    }

    /// @notice Only the in-route rise is repatriated: a balance the account already held in the input
    ///         currency stays where it is.
    function test_increase_changeToAccount_leavesPreExistingBalanceAlone() public {
        address account = marginRouter.accountOf(address(this), 0);
        uint256 idle = 1 ether;
        MockERC20(Currency.unwrap(debt)).transfer(account, idle);

        (bytes memory cmds, bytes[] memory ins) = _custodyRoute(debt, collateral, BUY, MAX_IN, account, account);
        _increase(0, cmds, ins);

        assertEq(_balance(debt, account), idle, "the earlier balance is untouched");
        assertLt(protocol.debtOf(account), MAX_IN, "and the refund was still credited");
    }

    // ─────────────────────────────── Pre-funded Universal Router ────────────────────────────────

    /// @notice A Universal Router pre-funded with more input than the route costs, with a trailing
    ///         whole-balance sweep to the router, no longer censors the increase: the credit is capped
    ///         at the spend, so the router's delta cannot turn positive. The excess stays on the router
    ///         (sweepable), and the position borrows nothing for a swap the donor paid for.
    function test_increase_preFundedUniversalRouter_cannotCensor() public {
        address account = marginRouter.accountOf(address(this), 0);
        MockERC20(Currency.unwrap(debt)).transfer(ur, MAX_IN);
        (bytes memory cmds, bytes[] memory ins) = _sweepSuffixedRoute(account);

        _increase(0, cmds, ins);

        assertEq(protocol.debtOf(account), 0, "the donor paid for the swap");
        assertGt(_balance(debt, address(marginRouter)), 0, "the excess donation sits on the router");
        assertEq(_balance(debt, ur), 0, "swept out of the Universal Router");
    }

    /// @notice A smaller pre-fund subsidizes the position by exactly that amount and nothing else.
    function test_increase_smallPreFund_subsidizesByTheDonation() public {
        address control = marginRouter.accountOf(address(this), 1);
        (bytes memory cmdsC, bytes[] memory insC) = _sweepSuffixedRoute(control);
        _increase(1, cmdsC, insC);
        uint256 cost = protocol.debtOf(control);

        uint256 donation = 0.5 ether;
        MockERC20(Currency.unwrap(debt)).transfer(ur, donation);
        address account = marginRouter.accountOf(address(this), 0);
        (bytes memory cmds, bytes[] memory ins) = _sweepSuffixedRoute(account);
        _increase(0, cmds, ins);

        assertApproxEqRel(protocol.debtOf(account) + donation, cost, 0.05e18, "borrow shrinks by the donation");
        assertEq(_balance(debt, address(marginRouter)), 0, "nothing stranded on the router");
    }

    // ──────────────────────────────────── Inventory-capped take ─────────────────────────────────

    /// @notice A `maxIn` above everything the PoolManager holds no longer blocks a route that needs
    ///         only a fraction of it: the flash-take and the Permit2 allowance are capped at the
    ///         inventory, and the position borrows the actual cost.
    function test_increase_maxInAboveInventory_isCappedNotBlocked() public {
        uint128 hugeMaxIn = 1e30;
        assertLt(_balance(debt, address(manager)), hugeMaxIn, "sanity: maxIn exceeds the pool inventory");
        address account = marginRouter.accountOf(address(this), 0);
        MockERC20(Currency.unwrap(collateral)).transfer(account, 1 ether);
        (bytes memory cmds, bytes[] memory ins) =
            buildV4ExactOutRoute(poolKey, debt, collateral, BUY, hugeMaxIn, account);

        marginRouter.increasePosition(
            IMarginRouter.IncreaseParams({
                adapter: adapter,
                market: market,
                equity: 0,
                collateralToBuy: BUY,
                maxDebtIn: hugeMaxIn,
                universalRouter: ur,
                routeCommands: cmds,
                routeInputs: ins,
                maxLtvAfter: Ltv.wrap(0),
                subId: 0,
                deadline: block.timestamp + 1
            })
        );

        assertEq(protocol.collateralOf(account), 1 ether + BUY, "collateral bought");
        assertGe(protocol.debtOf(account), BUY, "debt covers the purchase");
        assertLt(protocol.debtOf(account), 3 ether, "debt is the actual cost");
        assertEq(_balance(debt, address(marginRouter)), 0, "router nets to zero");
    }

    // ─────────────────────────────────────── Full close ─────────────────────────────────────────

    /// @notice A full close whose route sends its unspent collateral to the account returns that
    ///         refund to the owner with the rest of the payout rather than stranding it in the account.
    function test_close_changeToAccount_refundReachesOwner() public {
        address account = marginRouter.accountOf(address(this), 0);
        (bytes memory openCmds, bytes[] memory openIns) =
            buildV4ExactOutRoute(poolKey, debt, collateral, BUY, MAX_IN, account);
        _increase(0, openCmds, openIns);

        uint256 collateralHeld = protocol.collateralOf(account);
        uint256 owed = protocol.debtOf(account);
        uint128 maxCollateralIn = 3 ether;
        (bytes memory cmds, bytes[] memory ins) =
            _custodyRoute(collateral, debt, uint128(owed), maxCollateralIn, account, account);

        uint256 before = _balance(collateral, address(this));
        marginRouter.decreasePosition(
            IMarginRouter.DecreaseParams({
                adapter: adapter,
                market: market,
                debtToRepay: type(uint256).max,
                maxCollateralIn: maxCollateralIn,
                universalRouter: ur,
                routeCommands: cmds,
                routeInputs: ins,
                maxLtvAfter: Ltv.wrap(0),
                subId: 0,
                deadline: block.timestamp + 1
            })
        );
        uint256 received = _balance(collateral, address(this)) - before;

        assertEq(protocol.debtOf(account), 0, "debt repaid");
        assertEq(protocol.collateralOf(account), 0, "collateral withdrawn");
        assertEq(_balance(collateral, account), 0, "no refund stranded in the account");
        assertEq(_balance(collateral, address(marginRouter)), 0, "router nets to zero");
        // the owner gets everything except the real swap cost, so more than the collateral net of the cap
        assertGt(received, collateralHeld - maxCollateralIn, "the refund is part of the payout");
        assertLt(received, collateralHeld, "the swap cost was paid");
    }

    // ───────────────────────────────────── execute plan edges ───────────────────────────────────

    /// @notice A `ROUTE_SWAP` that runs before `SET_ACCOUNT` has no active account, so nothing is
    ///         repatriated: the change stays where the route sent it and the router owes the full cap.
    function test_execute_routeBeforeSetAccount_doesNotRepatriate() public {
        address account = marginRouter.accountOf(address(this), 0);
        MockERC20(Currency.unwrap(debt)).approve(address(permit2), type(uint256).max);
        permit2.approve(Currency.unwrap(debt), address(marginRouter), type(uint160).max, type(uint48).max);

        (bytes memory cmds, bytes[] memory ins) = _custodyRoute(debt, collateral, BUY, MAX_IN, account, account);
        Plan memory plan = Planner.init();
        plan = plan.add(MarginActions.ROUTE_SWAP, abi.encode(ur, debt, uint256(MAX_IN), cmds, ins));
        plan = plan.add(Actions.SETTLE, abi.encode(debt, uint256(ActionConstants.OPEN_DELTA), true));

        uint256 before = _balance(debt, address(this));
        marginRouter.execute(plan.encode(), block.timestamp + 1);

        assertEq(before - _balance(debt, address(this)), MAX_IN, "the caller paid the whole cap");
        assertGt(_balance(debt, account), 0, "the change stayed in the account");
    }

    /// @notice `type(uint160).max` is the one Permit2 allowance that is never decremented, so the
    ///         spend could not be measured; it is rejected.
    function test_execute_unboundedMaxIn_reverts() public {
        address account = marginRouter.accountOf(address(this), 0);
        (bytes memory cmds, bytes[] memory ins) =
            _custodyRoute(debt, collateral, BUY, MAX_IN, account, ActionConstants.MSG_SENDER);
        Plan memory plan = Planner.init();
        plan = plan.add(MarginActions.SET_ACCOUNT, abi.encode(uint256(0)));
        plan = plan.add(MarginActions.ROUTE_SWAP, abi.encode(ur, debt, uint256(type(uint160).max), cmds, ins));

        vm.expectRevert(IMarginRouter.UnboundedRouteAllowance.selector);
        marginRouter.execute(plan.encode(), block.timestamp + 1);
    }
}
