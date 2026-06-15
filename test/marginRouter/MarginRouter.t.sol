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
import {Ltv, toLtv} from "../../src/types/Ltv.sol";
import {NotOwner, ZeroOwner, NotPendingOwner} from "../../src/types/Owner.sol";

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
        p.poolKey = PoolKey({currency0: c0, currency1: c1, fee: 3000, tickSpacing: 60, hooks: IHooks(address(0))});
        p.equity = 1e18;
        p.collateralToBuy = 2e18;
        p.maxDebtIn = 1;
        p.deadline = block.timestamp + 1 hours;
    }

    function test_factory_managerIsRouter() public view {
        // the router inherits the factory mixin, so it is the manager baked into every account
        assertEq(router.manager(), address(router));
    }

    function test_accountOf_isDeterministic() public view {
        assertEq(router.accountOf(owner, 0), router.accountOf(owner, 0));
        assertTrue(router.accountOf(owner, 0) != router.accountOf(owner, 1));
    }

    function test_openPosition_revertsWhenSlippageBoundZero() public {
        IMarginRouter.OpenParams memory p = _openParams();
        p.maxDebtIn = 0;
        vm.expectRevert(IMarginRouter.SlippageBoundRequired.selector);
        router.openPosition(p);
    }

    function test_openPosition_revertsWhenCollateralToBuyZero() public {
        IMarginRouter.OpenParams memory p = _openParams();
        p.collateralToBuy = 0;
        vm.expectRevert(IMarginRouter.SlippageBoundRequired.selector);
        router.openPosition(p);
    }

    function test_increasePosition_revertsWhenCollateralToBuyZero() public {
        IMarginRouter.OpenParams memory p = _openParams();
        p.collateralToBuy = 0;
        vm.expectRevert(IMarginRouter.SlippageBoundRequired.selector);
        router.increasePosition(p);
    }

    function test_decreasePosition_revertsWhenDebtToRepayZero() public {
        IMarginRouter.DecreaseParams memory p;
        p.deadline = block.timestamp + 1 hours;
        p.debtToRepay = 0;
        p.maxCollateralIn = 1;
        p.maxLtvAfter = toLtv(0.9e18);
        vm.expectRevert(IMarginRouter.SlippageBoundRequired.selector);
        router.decreasePosition(p);
    }

    function test_openPosition_revertsAfterDeadline() public {
        IMarginRouter.OpenParams memory p = _openParams();
        p.deadline = block.timestamp - 1;
        vm.expectRevert(abi.encodeWithSelector(IMarginRouter.DeadlinePassed.selector, p.deadline));
        router.openPosition(p);
    }

    function test_closePosition_revertsWhenSlippageBoundZero() public {
        // the slippage bound only gates the swap path, so the position must carry debt to reach it
        IMarginRouter.CloseParams memory p;
        p.adapter = ILendingAdapter(makeAddr("adapter"));
        p.deadline = block.timestamp + 1 hours;
        p.maxCollateralIn = 0;
        vm.mockCall(
            address(p.adapter),
            abi.encodeWithSelector(ILendingAdapter.positionOf.selector),
            abi.encode(uint256(1e18), uint256(1e18))
        );
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

    function test_transferGovernance_onlyGovernance() public {
        vm.prank(makeAddr("stranger"));
        vm.expectRevert(abi.encodeWithSelector(NotOwner.selector, makeAddr("stranger")));
        router.transferGovernance(makeAddr("newGov"));
    }

    function test_transferGovernance_revertsForZeroAddress() public {
        vm.expectRevert(ZeroOwner.selector);
        router.transferGovernance(address(0));
    }

    function test_transferGovernance_proposesWithoutChangingGovernance() public {
        address newGov = makeAddr("newGov");
        router.transferGovernance(newGov);
        // current governance is unchanged until the successor accepts
        assertEq(router.governance(), address(this));
        assertEq(router.pendingGovernance(), newGov);
    }

    function test_acceptGovernance_completesHandoff() public {
        address newGov = makeAddr("newGov");
        router.transferGovernance(newGov);

        vm.prank(newGov);
        router.acceptGovernance();

        assertEq(router.governance(), newGov);
        assertEq(router.pendingGovernance(), address(0));
    }

    function test_oldGovernanceRetainsPowerUntilAccept() public {
        address newGov = makeAddr("newGov");
        router.transferGovernance(newGov);
        // the old governance can still curate the allowlist before the handoff completes
        router.setAdapterAllowed(ILendingAdapter(address(0xA)), true);
        assertTrue(router.isAdapterAllowed(ILendingAdapter(address(0xA))));
    }

    function test_acceptGovernance_revertsForNonPendingCaller() public {
        router.transferGovernance(makeAddr("newGov"));
        vm.prank(makeAddr("stranger"));
        vm.expectRevert(abi.encodeWithSelector(NotPendingOwner.selector, makeAddr("stranger")));
        router.acceptGovernance();
    }

    function test_acceptGovernance_revertsWhenNonePending() public {
        vm.prank(makeAddr("stranger"));
        vm.expectRevert(abi.encodeWithSelector(NotPendingOwner.selector, makeAddr("stranger")));
        router.acceptGovernance();
    }

    function test_openPosition_revertsWhenAdapterNotAllowed() public {
        // _openParams leaves adapter as the zero address, which is not allowlisted
        IMarginRouter.OpenParams memory p = _openParams();
        vm.expectRevert(abi.encodeWithSelector(IMarginRouter.AdapterNotAllowed.selector, address(0)));
        router.openPosition(p);
    }
}
