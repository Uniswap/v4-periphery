// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {RoutingTestHelpers} from "../shared/RoutingTestHelpers.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

import {IWETH9} from "../../src/interfaces/external/IWETH9.sol";
import {MarginRouter} from "../../src/MarginRouter.sol";
import {IMarginRouter} from "../../src/interfaces/IMarginRouter.sol";
import {MarginAccount} from "../../src/MarginAccount.sol";
import {Market} from "../../src/types/Market.sol";
import {Ltv, toLtv} from "../../src/types/Ltv.sol";
import {MockLendingAdapter} from "../mocks/MockLendingAdapter.sol";
import {MockLendingProtocol} from "../mocks/MockLendingProtocol.sol";

/// @notice End-to-end integration of the leverage flows against a real local PoolManager and pool,
///         with a mock lending protocol standing in for Morpho. Validates that the flash-style plan
///         assembly nets to zero and produces the expected position.
contract MarginRouterIntegrationTest is RoutingTestHelpers {
    MarginRouter internal marginRouter;
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
        poolKey = key0; // (currency0, currency1) pool with deep 1:1 liquidity
        market = Market({collateral: collateral, debt: debt});

        protocol = new MockLendingProtocol(IERC20(Currency.unwrap(collateral)), IERC20(Currency.unwrap(debt)));
        adapter = new MockLendingAdapter(address(protocol));
        adapter.setSupported(market, true);

        address impl = address(new MarginAccount());
        marginRouter = new MarginRouter(manager, IAllowanceTransfer(address(0xdead)), IWETH9(address(0xbeef)), impl);
        marginRouter.setAdapterAllowed(adapter, true);

        // fund the lending protocol with debt to lend out
        MockERC20(Currency.unwrap(debt)).transfer(address(protocol), 1_000_000 ether);
    }

    function _open(uint256 equity, uint128 buy) internal returns (address account) {
        account = marginRouter.accountOf(address(this), 0);
        // provide equity directly to the account; equity=0 in params avoids the permit2 pull
        MockERC20(Currency.unwrap(collateral)).transfer(account, equity);
        marginRouter.openPosition(
            IMarginRouter.OpenParams({
                adapter: adapter,
                market: market,
                poolKey: poolKey,
                equity: 0,
                collateralToBuy: buy,
                maxDebtIn: 5 ether,
                minHopPriceX36: 0,
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

    function test_closeLong_repaysAndReturnsResidual() public {
        address account = _open(1 ether, 2 ether);

        uint256 callerCollateralBefore = IERC20(Currency.unwrap(collateral)).balanceOf(address(this));

        marginRouter.closePosition(
            IMarginRouter.CloseParams({
                adapter: adapter,
                market: market,
                poolKey: poolKey,
                maxCollateralIn: 5 ether,
                minHopPriceX36: 0,
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

    function test_closePosition_zeroDebt_returnsCollateral() public {
        address account = _open(1 ether, 2 ether);
        // the position holds collateral supplied during the open
        assertEq(protocol.collateralOf(account), 3 ether, "collateral supplied");

        // simulate the debt being cleared out of band (e.g. repaid directly or fully liquidated),
        // leaving collateral but no debt
        protocol.setDebt(account, 0);

        uint256 callerBefore = IERC20(Currency.unwrap(collateral)).balanceOf(address(this));

        // a zero-debt close takes the swap-free path: collateral is withdrawn straight to the caller
        marginRouter.closePosition(
            IMarginRouter.CloseParams({
                adapter: adapter,
                market: market,
                poolKey: poolKey,
                maxCollateralIn: 0, // no swap, so no slippage bound is required
                minHopPriceX36: 0,
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

    function test_closeLong_doesNotSweepDonatedBalance() public {
        address account = _open(1 ether, 2 ether);

        // a stray balance lands on the router (e.g. a donation or dust from another flow)
        uint256 donation = 0.5 ether;
        MockERC20(Currency.unwrap(collateral)).transfer(address(marginRouter), donation);

        uint256 callerBefore = IERC20(Currency.unwrap(collateral)).balanceOf(address(this));

        marginRouter.closePosition(
            IMarginRouter.CloseParams({
                adapter: adapter,
                market: market,
                poolKey: poolKey,
                maxCollateralIn: 5 ether,
                minHopPriceX36: 0,
                subId: 0,
                deadline: block.timestamp + 1
            })
        );

        // the caller receives only their own realized residual; the donation stays in the router
        uint256 callerGain = IERC20(Currency.unwrap(collateral)).balanceOf(address(this)) - callerBefore;
        assertGt(callerGain, 0, "caller receives their own residual");
        assertEq(
            IERC20(Currency.unwrap(collateral)).balanceOf(address(marginRouter)),
            donation,
            "donated balance is left in the router, not swept to the caller"
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
        marginRouter.closePosition(
            IMarginRouter.CloseParams({
                adapter: adapter,
                market: market,
                poolKey: poolKey,
                maxCollateralIn: 5 ether,
                minHopPriceX36: 0,
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
        marginRouter.decreasePosition(
            IMarginRouter.DecreaseParams({
                adapter: adapter,
                market: market,
                poolKey: poolKey,
                debtToRepay: 1 ether,
                maxCollateralIn: 2 ether,
                minHopPriceX36: 0,
                maxLtvAfter: toLtv(0.9e18),
                subId: 0,
                deadline: block.timestamp + 1
            })
        );

        assertLt(protocol.debtOf(account), debtAfterOpen, "debt reduced");
        assertGt(protocol.debtOf(account), 0, "position still open");
    }

    function test_openLong_emitsPositionOpened() public {
        address account = marginRouter.accountOf(address(this), 0);
        MockERC20(Currency.unwrap(collateral)).transfer(account, 1 ether);

        vm.expectEmit(true, true, false, true, address(marginRouter));
        emit IMarginRouter.PositionOpened(address(this), account, collateral, debt, 2 ether);

        marginRouter.openPosition(
            IMarginRouter.OpenParams({
                adapter: adapter,
                market: market,
                poolKey: poolKey,
                equity: 0,
                collateralToBuy: 2 ether,
                maxDebtIn: 5 ether,
                minHopPriceX36: 0,
                subId: 0,
                deadline: block.timestamp + 1
            })
        );
    }

    function test_increasePosition_addsLeverage() public {
        address account = _open(1 ether, 2 ether);
        uint256 debtAfterOpen = protocol.debtOf(account);

        marginRouter.increasePosition(
            IMarginRouter.OpenParams({
                adapter: adapter,
                market: market,
                poolKey: poolKey,
                equity: 0,
                collateralToBuy: 1 ether,
                maxDebtIn: 3 ether,
                minHopPriceX36: 0,
                subId: 0,
                deadline: block.timestamp + 1
            })
        );
        vm.snapshotGasLastCall("MarginRouter_increasePosition");

        assertEq(protocol.collateralOf(account), 4 ether, "collateral grew by the bought amount");
        assertGt(protocol.debtOf(account), debtAfterOpen, "debt grew");
    }

    function test_decreasePosition_delevers() public {
        address account = _open(1 ether, 2 ether);
        uint256 debtAfterOpen = protocol.debtOf(account);
        uint256 collateralAfterOpen = protocol.collateralOf(account);

        marginRouter.decreasePosition(
            IMarginRouter.DecreaseParams({
                adapter: adapter,
                market: market,
                poolKey: poolKey,
                debtToRepay: 1 ether,
                maxCollateralIn: 2 ether,
                minHopPriceX36: 0,
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
        _open(1 ether, 2 ether);
        vm.expectRevert(IMarginRouter.PositionUnhealthy.selector);
        marginRouter.decreasePosition(
            IMarginRouter.DecreaseParams({
                adapter: adapter,
                market: market,
                poolKey: poolKey,
                debtToRepay: 1 ether,
                maxCollateralIn: 2 ether,
                minHopPriceX36: 0,
                maxLtvAfter: toLtv(0.5e18),
                subId: 0,
                deadline: block.timestamp + 1
            })
        );
    }
}
