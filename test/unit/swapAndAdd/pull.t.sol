// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {ISwapAndAdd} from "../../../src/interfaces/ISwapAndAdd.sol";
import {BttBase} from "./BttBase.sol";

contract PullTest is BttBase {
    using CurrencyLibrary for Currency;

    MockERC20 internal fundingToken;

    function setUp() public override {
        super.setUp();
        fundingToken = new MockERC20("FUND", "FUND", 18);
        fundingToken.mint(address(this), 1_000e18);
        fundingToken.approve(address(permit2), type(uint256).max);
        permit2.approve(address(fundingToken), address(zap), type(uint160).max, type(uint48).max);
    }

    function _funding(Currency token, uint256 amount) internal pure returns (ISwapAndAdd.TokenAmount[] memory funding) {
        funding = new ISwapAndAdd.TokenAmount[](1);
        funding[0] = ISwapAndAdd.TokenAmount({token: token, amount: amount});
    }

    function test_WhenFundingWithoutRoute_Reverts() public {
        // it reverts with {RouteFundingRequiresRoute}
        vm.expectRevert(ISwapAndAdd.RouteFundingRequiresRoute.selector);
        zap.exposedPull(key, 0, 0, _funding(Currency.wrap(address(fundingToken)), 1e18), "");
    }

    modifier givenFundingAndRoute() {
        _;
    }

    function test_WhenFundingTokenIsCurrency0_Reverts() public givenFundingAndRoute {
        // it reverts with {InvalidFundingToken}
        vm.expectRevert(abi.encodeWithSelector(ISwapAndAdd.InvalidFundingToken.selector, currency0));
        zap.exposedPull(key, 0, 0, _funding(currency0, 1e18), ROUTE_PAYLOAD);
    }

    function test_WhenFundingTokenIsCurrency1_Reverts() public givenFundingAndRoute {
        // it reverts with {InvalidFundingToken}
        vm.expectRevert(abi.encodeWithSelector(ISwapAndAdd.InvalidFundingToken.selector, currency1));
        zap.exposedPull(key, 0, 0, _funding(currency1, 1e18), ROUTE_PAYLOAD);
    }

    function test_WhenFundingTokenIsNative_AddsToExpectedValue() public givenFundingAndRoute {
        // it adds the amount to expectedValue
        uint256 amount = 1e18;
        uint256 zapEthBefore = address(zap).balance;
        zap.exposedPull{value: amount}(key, 0, 0, _funding(CurrencyLibrary.ADDRESS_ZERO, amount), ROUTE_PAYLOAD);
        assertEq(address(zap).balance, zapEthBefore + amount, "native funding sits on the zap");
    }

    function test_WhenFundingTokenIsErc20AndAmountGtZero_PullsViaPermit2() public givenFundingAndRoute {
        // it pulls the amount via Permit2 into the zap
        uint256 amount = 5e18;
        uint256 beforeThis = fundingToken.balanceOf(address(this));
        zap.exposedPull(key, 0, 0, _funding(Currency.wrap(address(fundingToken)), amount), ROUTE_PAYLOAD);
        assertEq(fundingToken.balanceOf(address(zap)), amount, "zap received funding");
        assertEq(fundingToken.balanceOf(address(this)), beforeThis - amount, "caller spent funding");
    }

    function test_WhenFundingTokenIsErc20AndAmountEqZero_PullsNothing() public givenFundingAndRoute {
        // it pulls nothing and still grants the Permit2 allowance
        uint256 beforeThis = fundingToken.balanceOf(address(this));
        zap.exposedPull(key, 0, 0, _funding(Currency.wrap(address(fundingToken)), 0), ROUTE_PAYLOAD);
        assertEq(fundingToken.balanceOf(address(zap)), 0, "no pull");
        assertEq(fundingToken.balanceOf(address(this)), beforeThis, "caller unchanged");
        (uint160 permitted,,) = permit2.allowance(address(zap), address(fundingToken), address(lpm));
        assertEq(permitted, type(uint160).max, "POSM allowance granted");
    }

    function test_WhenCurrency0IsNative_AddsAmount0ToExpectedValue() public {
        // it adds amount0In to expectedValue
        uint256 amount0 = 2e17;
        uint256 zapEthBefore = address(zap).balance;
        zap.exposedPull{value: amount0}(nativeKey, amount0, 0, _emptyFunding(), "");
        assertEq(address(zap).balance, zapEthBefore + amount0, "native budget sits on the zap");
    }

    function test_WhenCurrency0IsErc20AndAmount0GtZero_PullsToken0() public {
        // it pulls amount0In via Permit2
        uint256 amount0 = 3e18;
        uint256 before = currency0.balanceOf(address(this));
        zap.exposedPull(key, amount0, 0, _emptyFunding(), "");
        assertEq(currency0.balanceOf(address(zap)), amount0, "zap token0");
        assertEq(currency0.balanceOf(address(this)), before - amount0, "caller token0");
    }

    function test_WhenCurrency0IsErc20AndAmount0EqZero_DoesNotPullToken0() public {
        // it does not pull currency0
        uint256 before = currency0.balanceOf(address(this));
        zap.exposedPull(key, 0, 1e18, _emptyFunding(), "");
        assertEq(currency0.balanceOf(address(zap)), 0, "no token0 pull");
        assertEq(currency0.balanceOf(address(this)), before, "caller token0 unchanged");
        assertEq(currency1.balanceOf(address(zap)), 1e18, "token1 pulled");
    }

    function test_WhenAmount1GtZero_PullsToken1() public {
        // it pulls amount1In via Permit2
        uint256 amount1 = 4e18;
        uint256 before = currency1.balanceOf(address(this));
        zap.exposedPull(key, 0, amount1, _emptyFunding(), "");
        assertEq(currency1.balanceOf(address(zap)), amount1, "zap token1");
        assertEq(currency1.balanceOf(address(this)), before - amount1, "caller token1");
    }

    function test_WhenMsgValueNeExpectedValue_Reverts() public {
        // it reverts with {InvalidEthValue}
        vm.expectRevert(ISwapAndAdd.InvalidEthValue.selector);
        zap.exposedPull{value: 1e17 - 1}(nativeKey, 1e17, 0, _emptyFunding(), "");
    }

    /// @dev Two native ops see the same msg.value, but native spending is balance-funded. The first op
    ///      consumes and sweeps the value, so the second hits this guard and reverts the whole batch.
    function test_WhenBalanceLtExpectedValue_Reverts() public {
        // it reverts with {InvalidEthValue}
        ISwapAndAdd.AddParams memory p = _addParams(1e17, 0);
        p.poolKey = nativeKey;
        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeCall(ISwapAndAdd.add, (p));
        calls[1] = abi.encodeCall(ISwapAndAdd.add, (p));
        vm.expectRevert(ISwapAndAdd.InvalidEthValue.selector);
        zap.multicall{value: 1e17}(calls);
    }
}
