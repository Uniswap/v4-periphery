// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {RoutingTestHelpers} from "../shared/RoutingTestHelpers.sol";
import {DeployPermit2} from "permit2/test/utils/DeployPermit2.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

import {IWETH9} from "../../src/interfaces/external/IWETH9.sol";
import {MarginRouter} from "../../src/MarginRouter.sol";
import {IMarginRouter} from "../../src/interfaces/IMarginRouter.sol";
import {MarginAccount} from "../../src/MarginAccount.sol";
import {Market} from "../../src/types/Market.sol";
import {Direction} from "../../src/types/Direction.sol";
import {MockLendingAdapter} from "../mocks/MockLendingAdapter.sol";
import {MockLendingProtocol} from "../mocks/MockLendingProtocol.sol";

/// @notice Validates the Permit2 equity-pull path: the router pulls the caller's equity into their
///         account via Permit2, rather than the equity being pre-funded.
contract MarginRouterPermit2Test is RoutingTestHelpers, DeployPermit2 {
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
        poolKey = key0;
        market = Market({collateral: collateral, debt: debt});

        protocol = new MockLendingProtocol(IERC20(Currency.unwrap(collateral)), IERC20(Currency.unwrap(debt)));
        adapter = new MockLendingAdapter(address(protocol));
        adapter.setSupported(market, true);

        address impl = address(new MarginAccount());
        marginRouter = new MarginRouter(manager, permit2, IWETH9(address(0xbeef)), impl);
        marginRouter.setAdapterAllowed(adapter, true);

        MockERC20(Currency.unwrap(debt)).transfer(address(protocol), 1_000_000 ether);

        // approve permit2 on the collateral, then authorize the router as a permit2 spender
        MockERC20(Currency.unwrap(collateral)).approve(address(permit2), type(uint256).max);
        permit2.approve(Currency.unwrap(collateral), address(marginRouter), type(uint160).max, type(uint48).max);
    }

    function test_openLong_pullsEquityViaPermit2() public {
        address account = marginRouter.accountOf(address(this), 0);

        // no pre-funding: equity is pulled from the caller through Permit2 by the router
        marginRouter.openPosition(
            IMarginRouter.OpenParams({
                adapter: adapter,
                market: market,
                direction: Direction.Long,
                poolKey: poolKey,
                equity: 1 ether,
                collateralToBuy: 2 ether,
                maxDebtIn: 5 ether,
                minHopPriceX36: 0,
                subId: 0,
                deadline: block.timestamp + 1
            })
        );

        assertEq(protocol.collateralOf(account), 3 ether, "permit2-pulled equity plus bought collateral supplied");
        assertGt(protocol.debtOf(account), 0, "debt drawn");
        assertEq(IERC20(Currency.unwrap(collateral)).balanceOf(account), 0, "no loose collateral left");
    }
}
