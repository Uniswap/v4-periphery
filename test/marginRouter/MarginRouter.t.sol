// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {IWETH9} from "../../src/interfaces/external/IWETH9.sol";
import {MarginRouter} from "../../src/MarginRouter.sol";
import {IMarginRouter} from "../../src/interfaces/IMarginRouter.sol";
import {MarginAccount} from "../../src/MarginAccount.sol";
import {ILendingAdapter} from "../../src/interfaces/ILendingAdapter.sol";
import {ILendingAdapter} from "../../src/interfaces/ILendingAdapter.sol";
import {Market} from "../../src/types/Market.sol";
import {Direction} from "../../src/types/Direction.sol";
import {NotOwner} from "../../src/types/Owner.sol";

/// @dev Unit tests for the router's wiring and pre-unlock guards. The swap-coupled leverage flows
///      (open, close end-to-end) run through a real PoolManager and are validated by the integration
///      and fork suite, not here.
contract MarginRouterTest is Test {
    MarginRouter internal router;
    address internal owner = makeAddr("owner");
    Currency internal c0 = Currency.wrap(address(0x1111));
    Currency internal c1 = Currency.wrap(address(0x2222));

    function setUp() public {
        vm.warp(1_000);
        address impl = address(new MarginAccount());
        // poolManager / permit2 / weth9 are not called on the tested (pre-unlock) paths
        router = new MarginRouter(
            IPoolManager(makeAddr("poolManager")),
            IAllowanceTransfer(makeAddr("permit2")),
            IWETH9(makeAddr("weth9")),
            impl
        );
    }

    function _openParams() internal view returns (IMarginRouter.OpenParams memory p) {
        p.market = Market({collateral: c0, debt: c1});
        p.direction = Direction.Long;
        p.poolKey = PoolKey({currency0: c0, currency1: c1, fee: 3000, tickSpacing: 60, hooks: IHooks(address(0))});
        p.equity = 1e18;
        p.collateralToBuy = 2e18;
        p.maxDebtIn = 1;
        p.deadline = block.timestamp + 1 hours;
    }

    function test_factory_managerIsRouter() public view {
        assertEq(router.factory().manager(), address(router));
    }

    function test_accountOf_matchesFactory() public view {
        assertEq(router.accountOf(owner, 0), router.factory().accountOf(owner, 0));
    }

    function test_openPosition_revertsWhenSlippageBoundZero() public {
        IMarginRouter.OpenParams memory p = _openParams();
        p.maxDebtIn = 0;
        vm.expectRevert(IMarginRouter.SlippageBoundRequired.selector);
        router.openPosition(p);
    }

    function test_openPosition_revertsAfterDeadline() public {
        IMarginRouter.OpenParams memory p = _openParams();
        p.deadline = block.timestamp - 1;
        vm.expectRevert(abi.encodeWithSelector(IMarginRouter.DeadlinePassed.selector, p.deadline));
        router.openPosition(p);
    }

    function test_closePosition_revertsWhenSlippageBoundZero() public {
        IMarginRouter.CloseParams memory p;
        p.deadline = block.timestamp + 1 hours;
        p.maxCollateralIn = 0;
        vm.expectRevert(IMarginRouter.SlippageBoundRequired.selector);
        router.closePosition(p);
    }

    function test_governance_isDeployer() public view {
        assertEq(router.governance(), address(this));
    }

    function test_setAdapterAllowed_onlyGovernance() public {
        vm.prank(makeAddr("stranger"));
        vm.expectRevert(abi.encodeWithSelector(NotOwner.selector, makeAddr("stranger")));
        router.setAdapterAllowed(ILendingAdapter(address(0xA)), true);
    }

    function test_openPosition_revertsWhenAdapterNotAllowed() public {
        // _openParams leaves adapter as the zero address, which is not allowlisted
        IMarginRouter.OpenParams memory p = _openParams();
        vm.expectRevert(abi.encodeWithSelector(IMarginRouter.AdapterNotAllowed.selector, address(0)));
        router.openPosition(p);
    }
}
