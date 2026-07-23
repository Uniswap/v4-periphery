// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {RoutingTestHelpers} from "../shared/RoutingTestHelpers.sol";
import {Plan, Planner} from "../shared/Planner.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {WETH} from "solmate/src/tokens/WETH.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

import {IWETH9} from "../../src/interfaces/external/IWETH9.sol";
import {MarginRouter} from "../../src/MarginRouter.sol";
import {IMarginRouter} from "../../src/interfaces/IMarginRouter.sol";
import {MarginAccount} from "../../src/MarginAccount.sol";
import {Actions} from "../../src/libraries/Actions.sol";
import {MarginActions} from "../../src/libraries/MarginActions.sol";
import {ActionConstants} from "../../src/libraries/ActionConstants.sol";
import {Market} from "../../src/types/Market.sol";
import {MockLendingAdapter} from "../mocks/MockLendingAdapter.sol";
import {MockLendingProtocol} from "../mocks/MockLendingProtocol.sol";

/// @notice Native-ETH `execute` flows against a real local PoolManager: the intercepted
///         WRAP/UNWRAP/SWEEP opcodes plus the router-balance PULL path. Uses a real WETH and a
///         WETH-collateral market; no swap pool is needed because these plans move value between
///         native, WETH, and the account without touching pool deltas. The CONTRACT_BALANCE paths
///         resolve the input currency's own balance, so a WETH/native argument transposition in the
///         intercepted bodies would wrap/unwrap the wrong balance and fail here.
contract MarginRouterExecuteNativeTest is RoutingTestHelpers {
    using Planner for Plan;

    MarginRouter internal marginRouter;
    MockLendingAdapter internal adapter;
    MockLendingProtocol internal protocol;
    WETH internal weth;
    MockERC20 internal debtToken;
    Market internal market;
    Currency internal wethCurrency;

    function setUp() public {
        // real PoolManager (execute calls poolManager.unlock); the swap pools it creates are unused
        setupRouterCurrenciesAndPoolsWithLiquidity();

        weth = new WETH();
        debtToken = new MockERC20("Debt", "DEBT", 18);
        wethCurrency = Currency.wrap(address(weth));
        market = Market({collateral: wethCurrency, debt: Currency.wrap(address(debtToken))});

        protocol = new MockLendingProtocol(IERC20(address(weth)), IERC20(address(debtToken)));
        adapter = new MockLendingAdapter(address(protocol));
        adapter.setSupported(market, true);

        address impl = address(new MarginAccount());
        marginRouter =
            new MarginRouter(manager, IAllowanceTransfer(address(0xdead)), IWETH9(address(weth)), impl, address(this));
        marginRouter.setAdapterAllowed(adapter, true);
    }

    function test_execute_nativeEquity_wrapPullSupply() public {
        address account = marginRouter.accountOf(address(this), 0);
        vm.deal(address(this), 1 ether);

        // native equity: WRAP the router's ETH to WETH, PULL that WETH into the account, supply it
        Plan memory plan = Planner.init();
        plan = plan.add(MarginActions.SET_ACCOUNT, abi.encode(uint256(0)));
        plan = plan.add(Actions.WRAP, abi.encode(ActionConstants.CONTRACT_BALANCE));
        plan =
            plan.add(MarginActions.PULL_TO_ACCOUNT, abi.encode(wethCurrency, ActionConstants.CONTRACT_BALANCE, false));
        plan =
            plan.add(MarginActions.ACCOUNT_SUPPLY_COLLATERAL, abi.encode(adapter, market, ActionConstants.OPEN_DELTA));
        marginRouter.execute{value: 1 ether}(plan.encode(), block.timestamp + 1);
        vm.snapshotGasLastCall("MarginRouter_execute_nativeEquity");

        assertEq(protocol.collateralOf(account), 1 ether, "native equity wrapped and supplied as WETH");
        assertEq(weth.balanceOf(address(protocol)), 1 ether, "protocol holds the WETH");
        assertEq(address(marginRouter).balance, 0, "router holds no ETH");
        assertEq(weth.balanceOf(address(marginRouter)), 0, "router holds no WETH");
    }

    function test_execute_exitToNative_withdrawUnwrapSweep() public {
        // seed a WETH collateral position via the native addCollateral path (no debt)
        vm.deal(address(this), 2 ether);
        address account = marginRouter.accountOf(address(this), 0);
        marginRouter.addCollateral{value: 2 ether}(
            IMarginRouter.AddCollateralParams({
                adapter: adapter, market: market, amount: 0, subId: 0, deadline: block.timestamp + 1
            })
        );
        assertEq(protocol.collateralOf(account), 2 ether, "position seeded");

        uint256 callerEthBefore = address(this).balance;

        // withdraw all WETH collateral to the router, unwrap to ETH, sweep the ETH to the caller
        Plan memory plan = Planner.init();
        plan = plan.add(MarginActions.SET_ACCOUNT, abi.encode(uint256(0)));
        plan = plan.add(
            MarginActions.ACCOUNT_WITHDRAW_COLLATERAL,
            abi.encode(adapter, market, uint256(2 ether), address(marginRouter))
        );
        plan = plan.add(Actions.UNWRAP, abi.encode(ActionConstants.CONTRACT_BALANCE));
        plan = plan.add(Actions.SWEEP, abi.encode(CurrencyLibrary.ADDRESS_ZERO, ActionConstants.MSG_SENDER));
        marginRouter.execute(plan.encode(), block.timestamp + 1);
        vm.snapshotGasLastCall("MarginRouter_execute_exitToNative");

        assertEq(protocol.collateralOf(account), 0, "collateral fully withdrawn");
        assertEq(address(this).balance - callerEthBefore, 2 ether, "caller received unwrapped ETH");
        assertEq(address(marginRouter).balance, 0, "router holds no ETH");
        assertEq(weth.balanceOf(address(marginRouter)), 0, "router holds no WETH");
    }
}
