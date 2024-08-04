// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {GasSnapshot} from "forge-gas-snapshot/GasSnapshot.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";

import {IV4Router} from "../../src/interfaces/IV4Router.sol";
import {RoutingTestHelpers} from "../shared/RoutingTestHelpers.sol";
import {Plan, Planner} from "../shared/Planner.sol";
import {Actions} from "../../src/libraries/Actions.sol";
import {ActionConstants} from "../../src/libraries/ActionConstants.sol";
import {BipsLibrary} from "../../src/libraries/BipsLibrary.sol";

contract PaymentsTests is RoutingTestHelpers, GasSnapshot {
    using CurrencyLibrary for Currency;
    using Planner for Plan;

    address bob = makeAddr("BOB");

    function setUp() public {
        setupRouterCurrenciesAndPoolsWithLiquidity();
        plan = Planner.init();
    }

    function test_settleTakePair() public {
        uint256 amountIn = 1 ether;
        uint256 expectedAmountOut = 992054607780215625;
        IV4Router.ExactInputSingleParams memory params =
            IV4Router.ExactInputSingleParams(key0, true, uint128(amountIn), 0, 0, bytes(""));

        plan = plan.add(Actions.SWAP_EXACT_IN_SINGLE, abi.encode(params));
        plan = plan.add(Actions.SETTLE_TAKE_PAIR, abi.encode(key0.currency0, key0.currency1));

        uint256 inputBalanceBefore = key0.currency0.balanceOfSelf();
        uint256 outputBalanceBefore = key0.currency1.balanceOfSelf();
        // router is empty before
        assertEq(currency0.balanceOf(address(router)), 0);
        assertEq(currency1.balanceOf(address(router)), 0);

        bytes memory data = plan.encode();
        router.executeActions(data);

        uint256 inputBalanceAfter = key0.currency0.balanceOfSelf();
        uint256 outputBalanceAfter = key0.currency1.balanceOfSelf();

        // router is empty
        assertEq(currency0.balanceOf(address(router)), 0);
        assertEq(currency1.balanceOf(address(router)), 0);
        // caller's balance changed by input and output amounts
        assertEq(inputBalanceBefore - inputBalanceAfter, amountIn);
        assertEq(outputBalanceAfter - outputBalanceBefore, expectedAmountOut);
    }

    function test_exactIn_settleAll_revertsSlippage() public {
        uint256 amountIn = 1 ether;
        IV4Router.ExactInputSingleParams memory params =
            IV4Router.ExactInputSingleParams(key0, true, uint128(amountIn), 0, 0, bytes(""));

        plan = plan.add(Actions.SWAP_EXACT_IN_SINGLE, abi.encode(params));
        plan = plan.add(Actions.SETTLE_ALL, abi.encode(key0.currency0, amountIn - 1));
        plan = plan.add(Actions.TAKE_ALL, abi.encode(key0.currency0, MIN_TAKE_AMOUNT));

        bytes memory data = plan.encode();
        vm.expectRevert(IV4Router.V4TooMuchRequested.selector);
        router.executeActions(data);
    }

    function test_exactIn_takeAll_revertsSlippage() public {
        uint256 amountIn = 1 ether;
        uint256 expectedAmountOut = 992054607780215625;
        IV4Router.ExactInputSingleParams memory params =
            IV4Router.ExactInputSingleParams(key0, true, uint128(amountIn), 0, 0, bytes(""));

        plan = plan.add(Actions.SWAP_EXACT_IN_SINGLE, abi.encode(params));
        plan = plan.add(Actions.SETTLE_ALL, abi.encode(key0.currency0, MAX_SETTLE_AMOUNT));
        plan = plan.add(Actions.TAKE_ALL, abi.encode(key0.currency0, expectedAmountOut + 1));

        bytes memory data = plan.encode();
        vm.expectRevert(IV4Router.V4TooLittleReceived.selector);
        router.executeActions(data);
    }

    function test_exactOut_settleAll_revertsSlippage() public {
        uint256 amountOut = 1 ether;
        uint256 expectedAmountIn = 1008049273448486163;

        IV4Router.ExactOutputSingleParams memory params =
            IV4Router.ExactOutputSingleParams(key0, true, uint128(amountOut), uint128(expectedAmountIn), 0, bytes(""));

        plan = plan.add(Actions.SWAP_EXACT_OUT_SINGLE, abi.encode(params));
        plan = plan.add(Actions.SETTLE_ALL, abi.encode(key0.currency0, expectedAmountIn - 1));
        plan = plan.add(Actions.TAKE_ALL, abi.encode(key0.currency0, MIN_TAKE_AMOUNT));

        bytes memory data = plan.encode();
        vm.expectRevert(IV4Router.V4TooMuchRequested.selector);
        router.executeActions(data);
    }

    function test_exactOut_takeAll_revertsSlippage() public {
        uint256 amountOut = 1 ether;
        uint256 expectedAmountIn = 1008049273448486163;

        IV4Router.ExactOutputSingleParams memory params =
            IV4Router.ExactOutputSingleParams(key0, true, uint128(amountOut), uint128(expectedAmountIn), 0, bytes(""));

        plan = plan.add(Actions.SWAP_EXACT_OUT_SINGLE, abi.encode(params));
        plan = plan.add(Actions.SETTLE_ALL, abi.encode(key0.currency0, MAX_SETTLE_AMOUNT));
        plan = plan.add(Actions.TAKE_ALL, abi.encode(key0.currency0, amountOut + 1));

        bytes memory data = plan.encode();
        vm.expectRevert(IV4Router.V4TooLittleReceived.selector);
        router.executeActions(data);
    }

    function test_exactOut_takeAll_settleAll_succeedsExactAmount() public {
        uint256 amountOut = 1 ether;
        uint256 expectedAmountIn = 1008049273448486163;

        IV4Router.ExactOutputSingleParams memory params =
            IV4Router.ExactOutputSingleParams(key0, true, uint128(amountOut), uint128(expectedAmountIn), 0, bytes(""));

        plan = plan.add(Actions.SWAP_EXACT_OUT_SINGLE, abi.encode(params));
        plan = plan.add(Actions.SETTLE_ALL, abi.encode(key0.currency0, expectedAmountIn));
        plan = plan.add(Actions.TAKE_ALL, abi.encode(key0.currency0, amountOut));

        bytes memory data = plan.encode();
        vm.expectRevert(IV4Router.V4TooLittleReceived.selector);
        router.executeActions(data);
    }

    function test_settleFromRouter_takeAll() public {
        uint256 amountIn = 1 ether;
        uint256 expectedAmountOut = 992054607780215625;
        IV4Router.ExactInputSingleParams memory params =
            IV4Router.ExactInputSingleParams(key0, true, uint128(amountIn), 0, 0, bytes(""));

        // seed the router with tokens
        key0.currency0.transfer(address(router), amountIn);

        uint256 inputBalanceBefore = key0.currency0.balanceOfSelf();
        uint256 outputBalanceBefore = key0.currency1.balanceOfSelf();

        // seeded tokens are in the router
        assertEq(currency0.balanceOf(address(router)), amountIn);
        assertEq(currency1.balanceOf(address(router)), 0);

        plan = plan.add(Actions.SWAP_EXACT_IN_SINGLE, abi.encode(params));
        plan = plan.add(Actions.SETTLE, abi.encode(key0.currency0, ActionConstants.CONTRACT_BALANCE, false));
        plan = plan.add(Actions.TAKE_ALL, abi.encode(key0.currency1, MIN_TAKE_AMOUNT));

        bytes memory data = plan.encode();
        router.executeActions(data);

        uint256 inputBalanceAfter = key0.currency0.balanceOfSelf();
        uint256 outputBalanceAfter = key0.currency1.balanceOfSelf();

        // router is empty
        assertEq(currency0.balanceOf(address(router)), 0);
        assertEq(currency1.balanceOf(address(router)), 0);
        // callers input balance didnt change, but output balance did
        assertEq(inputBalanceBefore, inputBalanceAfter);
        assertEq(outputBalanceAfter - outputBalanceBefore, expectedAmountOut);
    }

    function test_settle_takePortion_takeAll() public {
        uint256 amountIn = 1 ether;
        uint256 expectedAmountOut = 992054607780215625;
        IV4Router.ExactInputSingleParams memory params =
            IV4Router.ExactInputSingleParams(key0, true, uint128(amountIn), 0, 0, bytes(""));

        plan = plan.add(Actions.SWAP_EXACT_IN_SINGLE, abi.encode(params));
        // take 15 bips to Bob
        plan = plan.add(Actions.TAKE_PORTION, abi.encode(key0.currency1, bob, 15));
        plan = plan.add(Actions.SETTLE_TAKE_PAIR, abi.encode(key0.currency0, key0.currency1));

        uint256 inputBalanceBefore = key0.currency0.balanceOfSelf();
        uint256 outputBalanceBefore = key0.currency1.balanceOfSelf();
        uint256 bobBalanceBefore = key0.currency1.balanceOf(bob);

        // router is empty before
        assertEq(currency0.balanceOf(address(router)), 0);
        assertEq(currency1.balanceOf(address(router)), 0);

        bytes memory data = plan.encode();
        router.executeActions(data);

        uint256 inputBalanceAfter = key0.currency0.balanceOfSelf();
        uint256 outputBalanceAfter = key0.currency1.balanceOfSelf();
        uint256 bobBalanceAfter = key0.currency1.balanceOf(bob);

        uint256 expectedFee = expectedAmountOut * 15 / BipsLibrary.BPS_DENOMINATOR;

        // router is empty
        assertEq(currency0.balanceOf(address(router)), 0);
        assertEq(currency1.balanceOf(address(router)), 0);
        // Bob got expectedFee, and the caller got the rest of the output
        assertEq(inputBalanceBefore - inputBalanceAfter, amountIn);
        assertEq(outputBalanceAfter - outputBalanceBefore, expectedAmountOut - expectedFee);
        assertEq(bobBalanceAfter - bobBalanceBefore, expectedFee);
    }

    function test_settle_takePortion_reverts() public {
        uint256 amountIn = 1 ether;
        IV4Router.ExactInputSingleParams memory params =
            IV4Router.ExactInputSingleParams(key0, true, uint128(amountIn), 0, 0, bytes(""));

        plan = plan.add(Actions.SWAP_EXACT_IN_SINGLE, abi.encode(params));
        // bips is larger than maximum bips
        plan = plan.add(Actions.TAKE_PORTION, abi.encode(key0.currency1, bob, BipsLibrary.BPS_DENOMINATOR + 1));
        plan = plan.add(Actions.SETTLE_TAKE_PAIR, abi.encode(key0.currency0, key0.currency1));

        bytes memory data = plan.encode();

        vm.expectRevert(BipsLibrary.InvalidBips.selector);
        router.executeActions(data);
    }
}
