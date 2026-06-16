// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {WETH} from "solmate/src/tokens/WETH.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

import {IWETH9} from "../../src/interfaces/external/IWETH9.sol";
import {MarginRouter} from "../../src/MarginRouter.sol";
import {IMarginRouter} from "../../src/interfaces/IMarginRouter.sol";
import {MarginAccount} from "../../src/MarginAccount.sol";
import {Market} from "../../src/types/Market.sol";
import {MockLendingAdapter} from "../mocks/MockLendingAdapter.sol";
import {MockLendingProtocol} from "../mocks/MockLendingProtocol.sol";

/// @notice Validates native-ETH equity: the router wraps msg.value to WETH and supplies it. Uses
///         addCollateral, which exercises the wrap path without needing a swap pool.
contract MarginRouterNativeTest is Test {
    MarginRouter internal router;
    MockLendingAdapter internal adapter;
    MockLendingProtocol internal protocol;
    WETH internal weth;
    MockERC20 internal debtToken;
    Market internal market;

    function setUp() public {
        weth = new WETH();
        debtToken = new MockERC20("Debt", "DEBT", 18);
        protocol = new MockLendingProtocol(IERC20(address(weth)), IERC20(address(debtToken)));
        adapter = new MockLendingAdapter(address(protocol));
        market = Market({collateral: Currency.wrap(address(weth)), debt: Currency.wrap(address(debtToken))});
        adapter.setSupported(market, true);

        address impl = address(new MarginAccount());
        // poolManager and permit2 are unused on the native addCollateral path
        router = new MarginRouter(
            IPoolManager(makeAddr("pm")), IAllowanceTransfer(makeAddr("permit2")), IWETH9(address(weth)), impl, address(this)
        );
        router.setAdapterAllowed(adapter, true);
    }

    function test_addCollateral_native_wrapsAndSupplies() public {
        address account = router.accountOf(address(this), 0);
        vm.deal(address(this), 1 ether);

        router.addCollateral{value: 1 ether}(
            IMarginRouter.AddCollateralParams({
                adapter: adapter, market: market, amount: 0, subId: 0, deadline: block.timestamp + 1
            })
        );
        vm.snapshotGasLastCall("MarginRouter_addCollateral_native");

        assertEq(protocol.collateralOf(account), 1 ether, "native equity wrapped and supplied as WETH");
        assertEq(weth.balanceOf(address(protocol)), 1 ether, "protocol holds the WETH");
        assertEq(address(router).balance, 0, "router holds no ETH");
    }

    function test_addCollateral_native_revertsWhenCollateralNotWeth() public {
        Market memory wrongMarket =
            Market({collateral: Currency.wrap(address(debtToken)), debt: Currency.wrap(address(weth))});
        adapter.setSupported(wrongMarket, true);
        vm.deal(address(this), 1 ether);

        vm.expectRevert(IMarginRouter.NativeCollateralMismatch.selector);
        router.addCollateral{value: 1 ether}(
            IMarginRouter.AddCollateralParams({
                adapter: adapter, market: wrongMarket, amount: 0, subId: 0, deadline: block.timestamp + 1
            })
        );
    }
}
