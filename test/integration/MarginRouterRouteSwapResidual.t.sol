// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {RoutingTestHelpers} from "../shared/RoutingTestHelpers.sol";
import {MarginRouteHelpers} from "../shared/MarginRouteHelpers.sol";
import {DeployPermit2} from "permit2/test/utils/DeployPermit2.sol";
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

/// @notice Regression suite for the `MarginRouter._routeSwap` flash-take netting fix.
///
///         Before the fix, `_routeSwap` settled the router's ENTIRE balance of the swap input
///         currency instead of only the unspent portion of its own flash-take, so anyone could send
///         a stray balance to the router (a plain ERC-20 transfer, no protocol interaction) and:
///           - underflow the partial-decrease `residual = balanceOfSelf() - balanceBefore` (panic 0x11);
///           - flip the router's delta positive so `increasePosition`'s `OPEN_DELTA` borrow reverted
///             `DeltaNotNegative`;
///           - or (donation < swap cost) silently subsidize/under-borrow the position.
///
///         The fix snapshots the router's input-currency balance before the flash-take and settles
///         only the increase attributable to this call, leaving any pre-existing balance untouched
///         (recoverable via SWEEP). These tests assert the curated flows now COMPLETE despite a
///         donation, and that the donation stays put on the router.
contract MarginRouterRouteSwapResidualTest is RoutingTestHelpers, MarginRouteHelpers, DeployPermit2 {
    IMarginRouter internal marginRouter;
    MockLendingAdapter internal adapter;
    MockLendingProtocol internal protocol;
    Market internal market;
    PoolKey internal poolKey;

    Currency internal collateral;
    Currency internal debt;

    address internal attacker = address(0xA11CE);

    function setUp() public {
        setupRouterCurrenciesAndPoolsWithLiquidity();

        collateral = currency0;
        debt = currency1;
        poolKey = key0;
        market = Market({collateral: collateral, debt: debt});

        protocol = new MockLendingProtocol(IERC20(Currency.unwrap(collateral)), IERC20(Currency.unwrap(debt)));
        adapter = new MockLendingAdapter(address(protocol));
        adapter.setSupported(market, true);

        address permit2 = deployPermit2();
        address impl = address(new MarginAccount());
        address ur = deployUniversalRouter(address(manager), permit2, address(0xbeef));
        marginRouter = IMarginRouter(
            deployMarginRouter(manager, IAllowanceTransfer(permit2), IWETH9(address(0xbeef)), impl, address(this), ur)
        );
        marginRouter.setAdapterAllowed(adapter, true);

        MockERC20(Currency.unwrap(debt)).transfer(address(protocol), 1_000_000 ether);
    }

    function _open(uint256 equity, uint128 buy) internal returns (address account) {
        account = marginRouter.accountOf(address(this), 0);
        MockERC20(Currency.unwrap(collateral)).transfer(account, equity);
        (bytes memory cmds, bytes[] memory ins) = buildV4ExactOutRoute(poolKey, debt, collateral, buy, 5 ether, account);
        marginRouter.increasePosition(
            IMarginRouter.IncreaseParams({
                adapter: adapter,
                market: market,
                equity: 0,
                collateralToBuy: buy,
                maxDebtIn: 5 ether,
                routeCommands: cmds,
                routeInputs: ins,
                maxLtvAfter: Ltv.wrap(0),
                subId: 0,
                deadline: block.timestamp + 1
            })
        );
    }

    function _delever() internal {
        address account = marginRouter.accountOf(address(this), 0);
        (bytes memory cmds, bytes[] memory ins) =
            buildV4ExactOutRoute(poolKey, collateral, debt, 1 ether, 2 ether, account);
        marginRouter.decreasePosition(
            IMarginRouter.DecreaseParams({
                adapter: adapter,
                market: market,
                debtToRepay: 1 ether,
                maxCollateralIn: 2 ether,
                routeCommands: cmds,
                routeInputs: ins,
                maxLtvAfter: toLtv(0.9e18),
                subId: 0,
                deadline: block.timestamp + 1
            })
        );
    }

    /// @notice Baseline: a partial decrease works with a clean router (donation-free control).
    function test_partialDecrease_baseline() public {
        _open(1 ether, 2 ether);
        _delever();
        assertEq(IERC20(Currency.unwrap(collateral)).balanceOf(address(marginRouter)), 0, "clean router nets to zero");
    }

    /// @notice After the fix, a 1-wei collateral donation no longer bricks a partial decrease; the
    ///         decrease completes and the donation is left untouched on the router (sweepable).
    function test_oneWeiDonation_doesNotBrickPartialDecrease() public {
        _open(1 ether, 2 ether);

        // a stray balance appears on the router (donor identity is irrelevant to the mechanism: any
        // party can raise it with a plain transfer to the router's known address)
        MockERC20(Currency.unwrap(collateral)).transfer(attacker, 1);
        vm.prank(attacker);
        MockERC20(Currency.unwrap(collateral)).transfer(address(marginRouter), 1);
        assertEq(IERC20(Currency.unwrap(collateral)).balanceOf(address(marginRouter)), 1, "1 wei donated");

        _delever(); // pre-fix: reverts panic 0x11; post-fix: succeeds

        assertEq(
            IERC20(Currency.unwrap(collateral)).balanceOf(address(marginRouter)),
            1,
            "donation is preserved, not swept into the pool"
        );
    }

    /// @notice A collateral donation larger than the swap cost no longer bricks a partial decrease.
    function test_largeDonation_doesNotBrickPartialDecrease() public {
        _open(1 ether, 2 ether);

        MockERC20(Currency.unwrap(collateral)).transfer(attacker, 3 ether);
        vm.prank(attacker);
        MockERC20(Currency.unwrap(collateral)).transfer(address(marginRouter), 3 ether);

        _delever(); // pre-fix: reverts DeltaNotNegative; post-fix: succeeds

        assertEq(
            IERC20(Currency.unwrap(collateral)).balanceOf(address(marginRouter)), 3 ether, "donation preserved intact"
        );
    }

    /// @notice A debt-token donation exceeding the swap cost no longer blocks `increasePosition`, and
    ///         the position is built on the caller's own equity (not subsidized by the donation).
    function test_debtDonation_doesNotBrickIncrease() public {
        MockERC20(Currency.unwrap(debt)).transfer(attacker, 5 ether);
        vm.prank(attacker);
        MockERC20(Currency.unwrap(debt)).transfer(address(marginRouter), 5 ether);

        address account = _open(1 ether, 2 ether); // pre-fix: reverts DeltaNotNegative; post-fix: succeeds

        assertEq(protocol.collateralOf(account), 3 ether, "collateral = equity + bought");
        assertGt(protocol.debtOf(account), 0, "debt drawn to fund the swap");
        assertEq(
            IERC20(Currency.unwrap(debt)).balanceOf(address(marginRouter)), 5 ether, "debt donation preserved intact"
        );
    }
}
