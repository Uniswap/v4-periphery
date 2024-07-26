// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {IV4Router} from "../../src/interfaces/IV4Router.sol";
import {RoutingTestHelpers} from "../shared/RoutingTestHelpers.sol";
import {Plan, ActionsRouterPlanner} from "../shared/ActionsRouterPlanner.sol";
import {Actions} from "../../src/libraries/Actions.sol";

contract V4RouterTest is RoutingTestHelpers {
    using CurrencyLibrary for Currency;
    using ActionsRouterPlanner for Plan;

    function setUp() public {
        setupRouterCurrenciesAndPoolsWithLiquidity();
        plan = ActionsRouterPlanner.init();
    }

    function test_swapExactInputSingle_zeroForOne() public {
        uint256 amountIn = 1 ether;
        uint256 expectedAmountOut = 992054607780215625;

        IV4Router.ExactInputSingleParams memory params =
            IV4Router.ExactInputSingleParams(key0, true, uint128(amountIn), 0, 0, bytes(""));

        uint256 prevBalance0 = key0.currency0.balanceOf(address(this));
        uint256 prevBalance1 = key0.currency1.balanceOf(address(this));

        plan = plan.add(Actions.SWAP_EXACT_IN_SINGLE, abi.encode(params));
        _finalizePlan(key0.currency0, key0.currency1, address(this));
        bytes memory data = plan.encode();

        router.executeActions(data);

        uint256 newBalance0 = key0.currency0.balanceOf(address(this));
        uint256 newBalance1 = key0.currency1.balanceOf(address(this));

        assertEq(prevBalance0 - newBalance0, amountIn);
        assertEq(newBalance1 - prevBalance1, expectedAmountOut);
    }

    function test_swapExactInputSingle_oneForZero() public {
        uint256 amountIn = 1 ether;
        uint256 expectedAmountOut = 992054607780215625;

        IV4Router.ExactInputSingleParams memory params =
            IV4Router.ExactInputSingleParams(key0, false, uint128(amountIn), 0, 0, bytes(""));

        uint256 prevBalance0 = key0.currency0.balanceOf(address(this));
        uint256 prevBalance1 = key0.currency1.balanceOf(address(this));

        plan = plan.add(Actions.SWAP_EXACT_IN_SINGLE, abi.encode(params));
        _finalizePlan(key0.currency1, key0.currency0, address(this));
        bytes memory data = plan.encode();

        router.executeActions(data);

        uint256 newBalance0 = key0.currency0.balanceOf(address(this));
        uint256 newBalance1 = key0.currency1.balanceOf(address(this));

        assertEq(prevBalance1 - newBalance1, amountIn);
        assertEq(newBalance0 - prevBalance0, expectedAmountOut);
    }

    function test_swapExactIn_1Hop_zeroForOne() public {
        uint256 amountIn = 1 ether;
        uint256 expectedAmountOut = 992054607780215625;

        tokenPath.push(currency0);
        tokenPath.push(currency1);
        IV4Router.ExactInputParams memory params = _getExactInputParams(tokenPath, amountIn);

        uint256 prevBalance0 = currency0.balanceOfSelf();
        uint256 prevBalance1 = currency1.balanceOfSelf();

        plan = plan.add(Actions.SWAP_EXACT_IN, abi.encode(params));
        _finalizePlan(currency0, currency1, address(this));
        bytes memory data = plan.encode();

        router.executeActions(data);

        uint256 newBalance0 = currency0.balanceOfSelf();
        uint256 newBalance1 = currency1.balanceOfSelf();

        assertEq(prevBalance0 - newBalance0, amountIn);
        assertEq(newBalance1 - prevBalance1, expectedAmountOut);
    }

    function test_swapExactIn_1Hop_oneForZero() public {
        uint256 amountIn = 1 ether;
        uint256 expectedAmountOut = 992054607780215625;

        tokenPath.push(currency1);
        tokenPath.push(currency0);
        IV4Router.ExactInputParams memory params = _getExactInputParams(tokenPath, amountIn);
        uint256 prevBalance0 = currency0.balanceOfSelf();
        uint256 prevBalance1 = currency1.balanceOfSelf();

        plan = plan.add(Actions.SWAP_EXACT_IN, abi.encode(params));
        _finalizePlan(currency1, currency0, address(this));
        bytes memory data = plan.encode();

        router.executeActions(data);

        uint256 newBalance0 = currency0.balanceOfSelf();
        uint256 newBalance1 = currency1.balanceOfSelf();

        assertEq(prevBalance1 - newBalance1, amountIn);
        assertEq(newBalance0 - prevBalance0, expectedAmountOut);
    }

    function test_swapExactIn_2Hops() public {
        uint256 amountIn = 1 ether;
        uint256 expectedAmountOut = 984211133872795298;

        tokenPath.push(currency0);
        tokenPath.push(currency1);
        tokenPath.push(currency2);
        IV4Router.ExactInputParams memory params = _getExactInputParams(tokenPath, amountIn);

        uint256 prevBalance0 = currency0.balanceOfSelf();
        uint256 prevBalance1 = currency1.balanceOfSelf();
        uint256 prevBalance2 = currency2.balanceOfSelf();

        plan = plan.add(Actions.SWAP_EXACT_IN, abi.encode(params));
        _finalizePlan(currency0, currency2, address(this));
        bytes memory data = plan.encode();

        router.executeActions(data);

        uint256 newBalance0 = currency0.balanceOfSelf();
        uint256 newBalance1 = currency1.balanceOfSelf();
        uint256 newBalance2 = currency2.balanceOfSelf();

        assertEq(prevBalance0 - newBalance0, amountIn);
        assertEq(prevBalance1 - newBalance1, 0);
        assertEq(newBalance2 - prevBalance2, expectedAmountOut);
        assertEq(currency0.balanceOf(address(router)), 0);
        assertEq(currency1.balanceOf(address(router)), 0);
        assertEq(currency2.balanceOf(address(router)), 0);
    }

    function test_swapExactIn_3Hops() public {
        uint256 amountIn = 1 ether;
        uint256 expectedAmountOut = 976467664490096191;

        tokenPath.push(currency0);
        tokenPath.push(currency1);
        tokenPath.push(currency2);
        tokenPath.push(currency3);
        IV4Router.ExactInputParams memory params = _getExactInputParams(tokenPath, amountIn);

        uint256 prevBalance0 = currency0.balanceOfSelf();
        uint256 prevBalance3 = currency3.balanceOfSelf();

        plan = plan.add(Actions.SWAP_EXACT_IN, abi.encode(params));
        _finalizePlan(currency0, currency3, address(this));
        bytes memory data = plan.encode();

        router.executeActions(data);

        uint256 newBalance0 = currency0.balanceOfSelf();
        uint256 newBalance3 = currency3.balanceOfSelf();

        assertEq(prevBalance0 - newBalance0, amountIn);
        assertEq(newBalance3 - prevBalance3, expectedAmountOut);
        assertEq(currency0.balanceOf(address(router)), 0);
        assertEq(currency1.balanceOf(address(router)), 0);
        assertEq(currency2.balanceOf(address(router)), 0);
        assertEq(currency3.balanceOf(address(router)), 0);
    }

    function test_swapExactOutputSingle_zeroForOne() public {
        uint256 amountOut = 1 ether;
        uint256 expectedAmountIn = 1008049273448486163;

        IV4Router.ExactOutputSingleParams memory params =
            IV4Router.ExactOutputSingleParams(key0, true, uint128(amountOut), 0, 0, bytes(""));

        uint256 prevBalance0 = key0.currency0.balanceOf(address(this));
        uint256 prevBalance1 = key0.currency1.balanceOf(address(this));

        plan = plan.add(Actions.SWAP_EXACT_OUT_SINGLE, abi.encode(params));
        _finalizePlan(key0.currency0, key0.currency1, address(this));
        bytes memory data = plan.encode();

        router.executeActions(data);

        uint256 newBalance0 = key0.currency0.balanceOf(address(this));
        uint256 newBalance1 = key0.currency1.balanceOf(address(this));

        assertEq(prevBalance0 - newBalance0, expectedAmountIn);
        assertEq(newBalance1 - prevBalance1, amountOut);
    }

    function test_swapExactOutputSingle_oneForZero() public {
        uint256 amountOut = 1 ether;
        uint256 expectedAmountIn = 1008049273448486163;

        IV4Router.ExactOutputSingleParams memory params =
            IV4Router.ExactOutputSingleParams(key0, false, uint128(amountOut), 0, 0, bytes(""));

        uint256 prevBalance0 = key0.currency0.balanceOf(address(this));
        uint256 prevBalance1 = key0.currency1.balanceOf(address(this));

        plan = plan.add(Actions.SWAP_EXACT_OUT_SINGLE, abi.encode(params));
        _finalizePlan(key0.currency1, key0.currency0, address(this));
        bytes memory data = plan.encode();

        router.executeActions(data);

        uint256 newBalance0 = key0.currency0.balanceOf(address(this));
        uint256 newBalance1 = key0.currency1.balanceOf(address(this));

        assertEq(prevBalance1 - newBalance1, expectedAmountIn);
        assertEq(newBalance0 - prevBalance0, amountOut);
    }

    function test_swapExactOut_1Hop_zeroForOne() public {
        uint256 amountOut = 1 ether;
        uint256 expectedAmountIn = 1008049273448486163;

        tokenPath.push(currency0);
        tokenPath.push(currency1);
        IV4Router.ExactOutputParams memory params = _getExactOutputParams(tokenPath, amountOut);

        uint256 prevBalance0 = currency0.balanceOfSelf();
        uint256 prevBalance1 = currency1.balanceOfSelf();

        plan = plan.add(Actions.SWAP_EXACT_OUT, abi.encode(params));
        _finalizePlan(currency0, currency1, address(this));
        bytes memory data = plan.encode();

        router.executeActions(data);

        uint256 newBalance0 = currency0.balanceOfSelf();
        uint256 newBalance1 = currency1.balanceOfSelf();

        assertEq(prevBalance0 - newBalance0, expectedAmountIn);
        assertEq(newBalance1 - prevBalance1, amountOut);
    }

    function test_swapExactOut_1Hop_oneForZero() public {
        uint256 amountOut = 1 ether;
        uint256 expectedAmountIn = 1008049273448486163;

        tokenPath.push(currency1);
        tokenPath.push(currency0);
        IV4Router.ExactOutputParams memory params = _getExactOutputParams(tokenPath, amountOut);

        uint256 prevBalance0 = currency0.balanceOfSelf();
        uint256 prevBalance1 = currency1.balanceOfSelf();

        plan = plan.add(Actions.SWAP_EXACT_OUT, abi.encode(params));
        _finalizePlan(currency1, currency0, address(this));
        bytes memory data = plan.encode();

        router.executeActions(data);

        uint256 newBalance0 = currency0.balanceOfSelf();
        uint256 newBalance1 = currency1.balanceOfSelf();

        assertEq(prevBalance1 - newBalance1, expectedAmountIn);
        assertEq(newBalance0 - prevBalance0, amountOut);
    }

    function test_swapExactOut_2Hops() public {
        uint256 amountOut = 1 ether;
        uint256 expectedAmountIn = 1016204441757464409;

        tokenPath.push(currency0);
        tokenPath.push(currency1);
        tokenPath.push(currency2);
        IV4Router.ExactOutputParams memory params = _getExactOutputParams(tokenPath, amountOut);

        uint256 prevBalance0 = currency0.balanceOfSelf();
        uint256 prevBalance1 = currency1.balanceOfSelf();
        uint256 prevBalance2 = currency2.balanceOfSelf();

        plan = plan.add(Actions.SWAP_EXACT_OUT, abi.encode(params));
        _finalizePlan(currency0, currency2, address(this));
        bytes memory data = plan.encode();

        router.executeActions(data);

        uint256 newBalance0 = currency0.balanceOfSelf();
        uint256 newBalance1 = currency1.balanceOfSelf();
        uint256 newBalance2 = currency2.balanceOfSelf();

        assertEq(prevBalance0 - newBalance0, expectedAmountIn);
        assertEq(prevBalance1 - newBalance1, 0);
        assertEq(newBalance2 - prevBalance2, amountOut);
        assertEq(currency0.balanceOf(address(router)), 0);
        assertEq(currency1.balanceOf(address(router)), 0);
        assertEq(currency2.balanceOf(address(router)), 0);
    }

    function test_swapExactOut_3Hops() public {
        uint256 amountOut = 1 ether;
        uint256 expectedAmountIn = 1024467570922834110;

        tokenPath.push(currency0);
        tokenPath.push(currency1);
        tokenPath.push(currency2);
        tokenPath.push(currency3);
        IV4Router.ExactOutputParams memory params = _getExactOutputParams(tokenPath, amountOut);

        uint256 prevBalance0 = currency0.balanceOfSelf();
        uint256 prevBalance3 = currency3.balanceOfSelf();

        plan = plan.add(Actions.SWAP_EXACT_OUT, abi.encode(params));
        _finalizePlan(currency0, currency3, address(this));
        bytes memory data = plan.encode();

        router.executeActions(data);

        uint256 newBalance0 = currency0.balanceOfSelf();
        uint256 newBalance3 = currency3.balanceOfSelf();

        assertEq(prevBalance0 - newBalance0, expectedAmountIn);
        assertEq(newBalance3 - prevBalance3, amountOut);
        assertEq(currency0.balanceOf(address(router)), 0);
        assertEq(currency1.balanceOf(address(router)), 0);
        assertEq(currency2.balanceOf(address(router)), 0);
        assertEq(currency3.balanceOf(address(router)), 0);
    }
}
