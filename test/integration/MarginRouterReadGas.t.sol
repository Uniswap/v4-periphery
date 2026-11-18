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

/// @notice The position reads that fill the rich events are best-effort, so an out-of-gas inside one
///         used to be swallowed like a venue revert: a curated call succeeded without its events at a
///         low gas limit and ran out of gas on the events at a slightly higher one, after the read had
///         just fit. These tests send each curated call at many gas limits, one level below the test
///         function so the limit is exactly what the router starts with, and check that the outcome is
///         monotone in the limit: a revert (`GasLimitTooLow` just under the threshold) or success with
///         the events, never a silent success. The mock read burns as much gas as a live read with
///         cold oracle feeds, which is what opened the silent window before the fix.
contract MarginRouterReadGasTest is RoutingTestHelpers, MarginRouteHelpers, DeployPermit2 {
    IAllowanceTransfer internal constant PERMIT2 = IAllowanceTransfer(0x000000000022D473030F116dDEE9F6B43aC78BA3);
    /// @dev A live read with the venue warm and the oracle feeds cold costs 76k to 106k on the four venues.
    uint256 internal constant LIVE_READ_GAS = 80_000;
    uint256 internal constant SCAN_STEP = 1_000;
    uint256 internal constant SCAN_BELOW = 120_000;
    uint256 internal constant SCAN_ABOVE = 50_000;

    IMarginRouter internal marginRouter;
    address internal ur;
    MockLendingAdapter internal adapter;
    MockLendingProtocol internal protocol;
    Market internal market;
    PoolKey internal poolKey;
    Currency internal collateral;
    Currency internal debt;

    enum Outcome {
        Reverted,
        SucceededWithoutEvents,
        SucceededWithEvents
    }

    function setUp() public {
        setupRouterCurrenciesAndPoolsWithLiquidity();
        collateral = currency0;
        debt = currency1;
        poolKey = key0;
        // 96 bytes of market data, the Morpho key shape, so the events carry the largest live payload
        market =
            Market({collateral: collateral, debt: debt, data: abi.encode(address(1), address(2), uint256(0.86e18))});

        protocol = new MockLendingProtocol(IERC20(Currency.unwrap(collateral)), IERC20(Currency.unwrap(debt)));
        adapter = new MockLendingAdapter(address(protocol));
        adapter.setSupported(market, true);
        adapter.setDescribeGasBurn(LIVE_READ_GAS);

        address permit2 = deployPermit2();
        address impl = address(new MarginAccount());
        ur = deployUniversalRouter(address(manager), permit2, address(0xbeef));
        marginRouter =
            IMarginRouter(deployMarginRouter(manager, IAllowanceTransfer(permit2), IWETH9(address(0xbeef)), impl));
        MockERC20(Currency.unwrap(debt)).transfer(address(protocol), 1_000_000 ether);

        MockERC20(Currency.unwrap(collateral)).approve(permit2, type(uint256).max);
        PERMIT2.approve(Currency.unwrap(collateral), address(marginRouter), type(uint160).max, type(uint48).max);
    }

    // -------------------------------------------------------------------------
    // The four curated paths are monotone in the gas limit
    // -------------------------------------------------------------------------

    function test_addCollateral_outcomeIsMonotoneInTheGasLimit() public {
        _open(1 ether, 2 ether);
        _assertMonotone(_addCollateralCall(0.5 ether), IMarginRouter.CollateralAdded.selector);
    }

    function test_increasePosition_outcomeIsMonotoneInTheGasLimit() public {
        address account = marginRouter.accountOf(address(this), 0);
        MockERC20(Currency.unwrap(collateral)).transfer(account, 1 ether);
        bytes memory data = abi.encodeCall(IMarginRouter.increasePosition, (_increaseParams(2 ether, account)));
        _assertMonotone(data, IMarginRouter.PositionIncreased.selector);
    }

    function test_partialDecrease_outcomeIsMonotoneInTheGasLimit() public {
        address account = _open(1 ether, 2 ether);
        _assertMonotone(_partialDecreaseCall(account), IMarginRouter.PositionDecreased.selector);
    }

    function test_zeroDebtClose_outcomeIsMonotoneInTheGasLimit() public {
        address account = _open(1 ether, 2 ether);
        protocol.setDebt(account, 0);
        _assertMonotone(_zeroDebtCloseCall(), IMarginRouter.PositionDecreased.selector);
    }

    /// @notice A limit one gas under the threshold rolls the whole action back, so a sender never
    ///         pays for a top-up that landed without its events.
    function test_addCollateral_underTheThreshold_rollsBackTheSupply() public {
        address account = _open(1 ether, 2 ether);
        bytes memory data = _addCollateralCall(0.5 ether);
        uint256 collateralBefore = protocol.collateralOf(account);
        uint256 lowest = _lowestWithEvents(data, IMarginRouter.CollateralAdded.selector);

        (bool ok, bytes memory ret) = this.callRouter(data, lowest - 1);
        assertFalse(ok, "reverts under the threshold");
        assertEq(ret, abi.encodeWithSelector(IMarginRouter.GasLimitTooLow.selector), "with GasLimitTooLow");
        assertEq(protocol.collateralOf(account), collateralBefore, "nothing supplied");
    }

    // -------------------------------------------------------------------------
    // The read budget bounds the read, not the action
    // -------------------------------------------------------------------------

    /// @notice A read dearer than the budget is skipped at every limit: the action completes and the
    ///         events are the only loss, exactly as for a venue revert.
    function test_readDearerThanBudget_completesWithoutEvents() public {
        address account = _open(1 ether, 2 ether);
        adapter.setDescribeGasBurn(marginRouter.POSITION_READ_GAS());

        vm.recordLogs();
        (bool ok,) = this.callRouter(_addCollateralCall(0.5 ether), 30_000_000);
        assertTrue(ok, "the top-up completes");
        assertEq(protocol.collateralOf(account), 3.5 ether, "collateral supplied");
        assertEq(
            _countRouterEvents(vm.getRecordedLogs(), IMarginRouter.CollateralAdded.selector), 0, "no CollateralAdded"
        );

        // the same read just inside the budget fills the events again
        adapter.setDescribeGasBurn(marginRouter.POSITION_READ_GAS() - 30_000);
        vm.recordLogs();
        (ok,) = this.callRouter(_addCollateralCall(0.5 ether), 30_000_000);
        assertTrue(ok, "the top-up completes");
        assertEq(_countRouterEvents(vm.getRecordedLogs(), IMarginRouter.CollateralAdded.selector), 1, "CollateralAdded");
    }

    /// @notice The increase has the same shape: a dear read costs `PositionIncreased`, not the open.
    function test_increase_readDearerThanBudget_opensWithoutPositionIncreased() public {
        address account = marginRouter.accountOf(address(this), 0);
        MockERC20(Currency.unwrap(collateral)).transfer(account, 1 ether);
        adapter.setDescribeGasBurn(marginRouter.POSITION_READ_GAS());

        vm.recordLogs();
        (bool ok,) = this.callRouter(
            abi.encodeCall(IMarginRouter.increasePosition, (_increaseParams(2 ether, account))), 30_000_000
        );
        assertTrue(ok, "the open completes");
        assertEq(protocol.collateralOf(account), 3 ether, "position opened");
        assertEq(
            _countRouterEvents(vm.getRecordedLogs(), IMarginRouter.PositionIncreased.selector),
            0,
            "no PositionIncreased"
        );
    }

    // -------------------------------------------------------------------------
    // Helpers
    // -------------------------------------------------------------------------

    /// @dev One level below the test function, so `gasLimit` is exactly what the router starts with.
    function callRouter(bytes calldata data, uint256 gasLimit) external returns (bool ok, bytes memory ret) {
        (ok, ret) = address(marginRouter).call{gas: gasLimit}(data);
    }

    /// @dev From the lowest completing limit, every lower limit reverts (one gas under it with
    ///      `GasLimitTooLow`) and every higher one completes with the event.
    function _assertMonotone(bytes memory data, bytes32 richEvent) internal {
        _outcome(data, 30_000_000, richEvent); // warm-up, so every probe sees the same warm state
        uint256 lowest = _lowestWithEvents(data, richEvent);

        (Outcome o, bytes memory ret) = _outcome(data, lowest - 1, richEvent);
        assertTrue(o == Outcome.Reverted, "one gas under the threshold reverts");
        assertEq(ret, abi.encodeWithSelector(IMarginRouter.GasLimitTooLow.selector), "with GasLimitTooLow");

        for (uint256 limit = lowest - SCAN_STEP; limit >= lowest - SCAN_BELOW; limit -= SCAN_STEP) {
            (o,) = _outcome(data, limit, richEvent);
            assertTrue(o == Outcome.Reverted, "no success below the completing limit");
        }
        for (uint256 limit = lowest; limit <= lowest + SCAN_ABOVE; limit += SCAN_STEP * 5) {
            (o,) = _outcome(data, limit, richEvent);
            assertTrue(o == Outcome.SucceededWithEvents, "every higher limit completes with the event");
        }
    }

    /// @dev Completing with the event is monotone in the limit, so its lowest limit can be bisected.
    function _lowestWithEvents(bytes memory data, bytes32 richEvent) internal returns (uint256 lo) {
        lo = 30_000;
        uint256 hi = 3_000_000;
        while (lo < hi) {
            uint256 mid = (lo + hi) / 2;
            (Outcome o,) = _outcome(data, mid, richEvent);
            if (o == Outcome.SucceededWithEvents) hi = mid;
            else lo = mid + 1;
        }
    }

    /// @dev Sends `data` at `gasLimit` on a state snapshot and classifies the result.
    function _outcome(bytes memory data, uint256 gasLimit, bytes32 richEvent)
        internal
        returns (Outcome o, bytes memory ret)
    {
        uint256 snap = vm.snapshotState();
        vm.recordLogs();
        bool ok;
        (ok, ret) = this.callRouter(data, gasLimit);
        uint256 events = _countRouterEvents(vm.getRecordedLogs(), richEvent);
        vm.revertToState(snap);
        if (!ok) return (Outcome.Reverted, ret);
        return (events > 0 ? Outcome.SucceededWithEvents : Outcome.SucceededWithoutEvents, ret);
    }

    function _countRouterEvents(Vm.Log[] memory logs, bytes32 topic) internal view returns (uint256 count) {
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == address(marginRouter) && logs[i].topics[0] == topic) count++;
        }
    }

    function _open(uint256 equity, uint128 buy) internal returns (address account) {
        account = marginRouter.accountOf(address(this), 0);
        MockERC20(Currency.unwrap(collateral)).transfer(account, equity);
        marginRouter.increasePosition(_increaseParams(buy, account));
    }

    function _increaseParams(uint128 buy, address account) internal view returns (IMarginRouter.IncreaseParams memory) {
        (bytes memory cmds, bytes[] memory ins) = buildV4ExactOutRoute(poolKey, debt, collateral, buy, 5 ether, account);
        return IMarginRouter.IncreaseParams({
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
        });
    }

    function _addCollateralCall(uint256 amount) internal view returns (bytes memory) {
        return abi.encodeCall(
            IMarginRouter.addCollateral,
            (IMarginRouter.AddCollateralParams({
                    adapter: adapter, market: market, amount: amount, subId: 0, deadline: block.timestamp + 1
                }))
        );
    }

    function _partialDecreaseCall(address account) internal view returns (bytes memory) {
        (bytes memory cmds, bytes[] memory ins) =
            buildV4ExactOutRoute(poolKey, collateral, debt, 1 ether, 2 ether, account);
        return abi.encodeCall(
            IMarginRouter.decreasePosition,
            (IMarginRouter.DecreaseParams({
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
                }))
        );
    }

    function _zeroDebtCloseCall() internal view returns (bytes memory) {
        return abi.encodeCall(
            IMarginRouter.decreasePosition,
            (IMarginRouter.DecreaseParams({
                    adapter: adapter,
                    market: market,
                    debtToRepay: type(uint256).max,
                    maxCollateralIn: 0,
                    universalRouter: ur,
                    routeCommands: "",
                    routeInputs: new bytes[](0),
                    maxLtvAfter: Ltv.wrap(0),
                    subId: 0,
                    deadline: block.timestamp + 1
                }))
        );
    }
}
