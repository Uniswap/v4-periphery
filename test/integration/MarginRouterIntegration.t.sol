// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {RoutingTestHelpers} from "../shared/RoutingTestHelpers.sol";
import {Vm} from "forge-std/Vm.sol";
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

        address impl = address(new MarginAccount());
        marginRouter = new MarginRouter(
            manager, IAllowanceTransfer(address(0xdead)), IWETH9(address(0xbeef)), impl, address(this)
        );
        marginRouter.setAdapterAllowed(adapter, true);

        // fund the lending protocol with debt to lend out
        MockERC20(Currency.unwrap(debt)).transfer(address(protocol), 1_000_000 ether);
    }

    function _open(uint256 equity, uint128 buy) internal returns (address account) {
        account = marginRouter.accountOf(address(this), 0);
        // provide equity directly to the account; equity=0 in params avoids the permit2 pull
        MockERC20(Currency.unwrap(collateral)).transfer(account, equity);
        marginRouter.increasePosition(
            IMarginRouter.IncreaseParams({
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

        marginRouter.decreasePosition(
            IMarginRouter.DecreaseParams({
                debtToRepay: type(uint256).max,
                maxLtvAfter: Ltv.wrap(0),
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

    function test_close_zeroDebt_returnsCollateral() public {
        address account = _open(1 ether, 2 ether);
        // the position holds collateral supplied during the open
        assertEq(protocol.collateralOf(account), 3 ether, "collateral supplied");

        // simulate the debt being cleared out of band (e.g. repaid directly or fully liquidated),
        // leaving collateral but no debt
        protocol.setDebt(account, 0);

        uint256 callerBefore = IERC20(Currency.unwrap(collateral)).balanceOf(address(this));

        // a zero-debt close takes the swap-free path: collateral is withdrawn straight to the caller
        marginRouter.decreasePosition(
            IMarginRouter.DecreaseParams({
                debtToRepay: type(uint256).max,
                maxLtvAfter: Ltv.wrap(0),
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

        marginRouter.decreasePosition(
            IMarginRouter.DecreaseParams({
                debtToRepay: type(uint256).max,
                maxLtvAfter: Ltv.wrap(0),
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
        marginRouter.decreasePosition(
            IMarginRouter.DecreaseParams({
                debtToRepay: type(uint256).max,
                maxLtvAfter: Ltv.wrap(0),
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

    function test_openLong_emitsPositionIncreased() public {
        address account = marginRouter.accountOf(address(this), 0);
        MockERC20(Currency.unwrap(collateral)).transfer(account, 1 ether);

        // decode the emitted event rather than predict the pool-dependent debt: the enriched fields
        // carry full resulting state so an indexer needs no follow-up RPC
        vm.recordLogs();
        marginRouter.increasePosition(
            IMarginRouter.IncreaseParams({
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
            assertEq(od.currentLtv, 0.86e18, "currentLtv (mock reports maxLtv)");
            assertEq(od.maxLtv, 0.86e18, "maxLtv (mock)");
            assertEq(od.healthFactorWad, 1e18, "healthFactor (currentLtv == maxLtv)");
        }
        assertTrue(found, "PositionIncreased emitted");
    }

    function test_increasePosition_addsLeverageToExistingPosition() public {
        address account = _open(1 ether, 2 ether);
        uint256 debtAfterOpen = protocol.debtOf(account);

        // a second open into the same account adds leverage to the existing position
        marginRouter.increasePosition(
            IMarginRouter.IncreaseParams({
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
        vm.snapshotGasLastCall("MarginRouter_increasePosition_addLeverage");

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
