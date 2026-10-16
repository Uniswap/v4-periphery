// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {RoutingTestHelpers} from "../shared/RoutingTestHelpers.sol";
import {Plan, Planner} from "../shared/Planner.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

import {IWETH9} from "../../src/interfaces/external/IWETH9.sol";
import {IMarginRouter} from "../../src/interfaces/IMarginRouter.sol";
import {MarginAccount} from "../../src/MarginAccount.sol";
import {NativeWrapper} from "../../src/base/NativeWrapper.sol";
import {Actions} from "../../src/libraries/Actions.sol";
import {MarginActions} from "../../src/libraries/MarginActions.sol";
import {ActionConstants} from "../../src/libraries/ActionConstants.sol";
import {Ltv} from "../../src/types/Ltv.sol";
import {Market} from "../../src/types/Market.sol";
import {MockLendingAdapter} from "../mocks/MockLendingAdapter.sol";
import {MockLendingProtocol} from "../mocks/MockLendingProtocol.sol";
import {MarginRouteHelpers} from "../shared/MarginRouteHelpers.sol";

/// @notice A router deployed with `weth9 = address(0)`: the deployment for a chain with no canonical
///         1:1 wrapped native (Arc, where native USDC and its ERC-20 interface are one balance in
///         different decimals). Every native path must revert `NativeNotSupported` by design rather
///         than by an accidental call into the zero address, and ERC-20 flows must be unaffected.
contract MarginRouterNoWeth9Test is RoutingTestHelpers, MarginRouteHelpers {
    using Planner for Plan;

    IMarginRouter internal marginRouter;
    MockLendingAdapter internal adapter;
    MockLendingProtocol internal protocol;
    MockERC20 internal collateralToken;
    MockERC20 internal debtToken;
    Market internal market;

    function setUp() public {
        // real PoolManager (execute calls poolManager.unlock); the swap pools it creates are unused
        setupRouterCurrenciesAndPoolsWithLiquidity();

        collateralToken = new MockERC20("Collateral", "COLL", 6);
        debtToken = new MockERC20("Debt", "DEBT", 18);
        market = Market({
            collateral: Currency.wrap(address(collateralToken)), debt: Currency.wrap(address(debtToken)), data: ""
        });

        protocol = new MockLendingProtocol(IERC20(address(collateralToken)), IERC20(address(debtToken)));
        adapter = new MockLendingAdapter(address(protocol));
        adapter.setSupported(market, true);

        address impl = address(new MarginAccount());
        // no WETH9: the chain has no 1:1 wrapper for its native token
        marginRouter =
            IMarginRouter(deployMarginRouter(manager, IAllowanceTransfer(address(0xdead)), IWETH9(address(0)), impl));
    }

    function test_addCollateral_native_revertsNativeNotSupported() public {
        vm.deal(address(this), 1 ether);
        vm.expectRevert(IMarginRouter.NativeNotSupported.selector);
        marginRouter.addCollateral{value: 1 ether}(
            IMarginRouter.AddCollateralParams({
                adapter: adapter, market: market, amount: 0, subId: 0, deadline: block.timestamp + 1
            })
        );
    }

    /// @dev With no WETH9 a zero-address collateral would pass the `NativeCollateralMismatch` check
    ///      (both sides are the zero address), so the explicit guard must fire first instead of the
    ///      wrap hitting an address with no code.
    function test_addCollateral_native_zeroAddressCollateral_revertsNativeNotSupported() public {
        Market memory nativeMarket =
            Market({collateral: CurrencyLibrary.ADDRESS_ZERO, debt: Currency.wrap(address(debtToken)), data: ""});
        adapter.setSupported(nativeMarket, true);
        vm.deal(address(this), 1 ether);

        vm.expectRevert(IMarginRouter.NativeNotSupported.selector);
        marginRouter.addCollateral{value: 1 ether}(
            IMarginRouter.AddCollateralParams({
                adapter: adapter, market: nativeMarket, amount: 0, subId: 0, deadline: block.timestamp + 1
            })
        );
    }

    function test_increasePosition_native_revertsNativeNotSupported() public {
        vm.deal(address(this), 1 ether);
        vm.expectRevert(IMarginRouter.NativeNotSupported.selector);
        marginRouter.increasePosition{value: 1 ether}(
            IMarginRouter.IncreaseParams({
                adapter: adapter,
                market: market,
                equity: 0,
                collateralToBuy: 1,
                maxDebtIn: 1,
                universalRouter: address(0),
                routeCommands: "",
                routeInputs: new bytes[](0),
                maxLtvAfter: Ltv.wrap(0),
                subId: 0,
                deadline: block.timestamp + 1
            })
        );
    }

    function test_execute_wrap_revertsNativeNotSupported() public {
        vm.deal(address(this), 1 ether);
        Plan memory plan = Planner.init();
        plan = plan.add(Actions.WRAP, abi.encode(ActionConstants.CONTRACT_BALANCE));

        vm.expectRevert(IMarginRouter.NativeNotSupported.selector);
        marginRouter.execute{value: 1 ether}(plan.encode(), block.timestamp + 1);
    }

    function test_execute_unwrap_revertsNativeNotSupported() public {
        Plan memory plan = Planner.init();
        plan = plan.add(Actions.UNWRAP, abi.encode(uint256(1)));

        vm.expectRevert(IMarginRouter.NativeNotSupported.selector);
        marginRouter.execute(plan.encode(), block.timestamp + 1);
    }

    /// @dev `NativeWrapper.receive` admits only WETH9 and the PoolManager; with WETH9 unset nothing
    ///      but the PoolManager can push native value onto the router.
    function test_receive_rejectsNativeFromAnyoneButPoolManager() public {
        vm.deal(address(this), 1);
        (bool ok, bytes memory ret) = address(marginRouter).call{value: 1}("");
        assertFalse(ok, "router accepted native value from a caller");
        assertEq(bytes4(ret), NativeWrapper.InvalidEthSender.selector);
    }

    /// @dev ERC-20 flows do not touch the wrapper: a plan that pulls the router's token balance into
    ///      the account and supplies it works exactly as on a deployment with WETH9.
    function test_execute_erc20PullSupply_worksWithoutWeth9() public {
        address account = marginRouter.accountOf(address(this), 0);
        collateralToken.mint(address(marginRouter), 1_000e6);

        Plan memory plan = Planner.init();
        plan = plan.add(MarginActions.SET_ACCOUNT, abi.encode(uint256(0)));
        plan = plan.add(
            MarginActions.PULL_TO_ACCOUNT, abi.encode(market.collateral, ActionConstants.CONTRACT_BALANCE, false)
        );
        plan =
            plan.add(MarginActions.ACCOUNT_SUPPLY_COLLATERAL, abi.encode(adapter, market, ActionConstants.OPEN_DELTA));
        marginRouter.execute(plan.encode(), block.timestamp + 1);

        assertEq(protocol.collateralOf(account), 1_000e6, "ERC-20 collateral supplied");
        assertEq(collateralToken.balanceOf(address(marginRouter)), 0, "router holds no collateral");
    }
}
