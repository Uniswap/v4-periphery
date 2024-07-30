// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {IV4Router} from "../../src/interfaces/IV4Router.sol";
import {RoutingTestHelpers} from "../shared/RoutingTestHelpers.sol";
import {Plan, Planner} from "../shared/Planner.sol";
import {Actions} from "../../src/libraries/Actions.sol";

contract V4RouterTest is RoutingTestHelpers {
    using CurrencyLibrary for Currency;
    using Planner for Plan;

    function setUp() public {
        setupRouterCurrenciesAndPoolsWithLiquidity();
        plan = Planner.init();
    }

    /*//////////////////////////////////////////////////////////////
                        ERC20 -> ERC20 EXACT INPUT
    //////////////////////////////////////////////////////////////*/

    function test_swapExactInputSingle_zeroForOne() public {
        uint256 amountIn = 1 ether;
        uint256 expectedAmountOut = 992054607780215625;

        IV4Router.ExactInputSingleParams memory params =
            IV4Router.ExactInputSingleParams(key0, true, uint128(amountIn), 0, 0, bytes(""));

        plan = plan.add(Actions.SWAP_EXACT_IN_SINGLE, abi.encode(params));
        (uint256 inputBalanceBefore, uint256 outputBalanceBefore, uint256 inputBalanceAfter, uint256 outputBalanceAfter)
        = _finalizeAndExecuteSwap(key0.currency0, key0.currency1, amountIn);

        assertEq(currency0.balanceOf(address(router)), 0);
        assertEq(currency1.balanceOf(address(router)), 0);

        assertEq(inputBalanceBefore - inputBalanceAfter, amountIn);
        assertEq(outputBalanceAfter - outputBalanceBefore, expectedAmountOut);
    }

    function test_swapExactInputSingle_oneForZero() public {
        uint256 amountIn = 1 ether;
        uint256 expectedAmountOut = 992054607780215625;

        IV4Router.ExactInputSingleParams memory params =
            IV4Router.ExactInputSingleParams(key0, false, uint128(amountIn), 0, 0, bytes(""));
        plan = plan.add(Actions.SWAP_EXACT_IN_SINGLE, abi.encode(params));

        (uint256 inputBalanceBefore, uint256 outputBalanceBefore, uint256 inputBalanceAfter, uint256 outputBalanceAfter)
        = _finalizeAndExecuteSwap(key0.currency1, key0.currency0, amountIn);

        assertEq(currency0.balanceOf(address(router)), 0);
        assertEq(currency1.balanceOf(address(router)), 0);

        assertEq(inputBalanceBefore - inputBalanceAfter, amountIn);
        assertEq(outputBalanceAfter - outputBalanceBefore, expectedAmountOut);
    }

    function test_swapExactIn_1Hop_zeroForOne() public {
        uint256 amountIn = 1 ether;
        uint256 expectedAmountOut = 992054607780215625;

        tokenPath.push(currency0);
        tokenPath.push(currency1);
        IV4Router.ExactInputParams memory params = _getExactInputParams(tokenPath, amountIn);
        plan = plan.add(Actions.SWAP_EXACT_IN, abi.encode(params));

        (uint256 inputBalanceBefore, uint256 outputBalanceBefore, uint256 inputBalanceAfter, uint256 outputBalanceAfter)
        = _finalizeAndExecuteSwap(currency0, currency1, amountIn);

        assertEq(currency0.balanceOf(address(router)), 0);
        assertEq(currency1.balanceOf(address(router)), 0);

        assertEq(inputBalanceBefore - inputBalanceAfter, amountIn);
        assertEq(outputBalanceAfter - outputBalanceBefore, expectedAmountOut);
    }

    function test_swapExactIn_1Hop_oneForZero() public {
        uint256 amountIn = 1 ether;
        uint256 expectedAmountOut = 992054607780215625;

        tokenPath.push(currency1);
        tokenPath.push(currency0);
        IV4Router.ExactInputParams memory params = _getExactInputParams(tokenPath, amountIn);

        plan = plan.add(Actions.SWAP_EXACT_IN, abi.encode(params));

        (uint256 inputBalanceBefore, uint256 outputBalanceBefore, uint256 inputBalanceAfter, uint256 outputBalanceAfter)
        = _finalizeAndExecuteSwap(currency1, currency0, amountIn);

        assertEq(currency0.balanceOf(address(router)), 0);
        assertEq(currency1.balanceOf(address(router)), 0);

        assertEq(inputBalanceBefore - inputBalanceAfter, amountIn);
        assertEq(outputBalanceAfter - outputBalanceBefore, expectedAmountOut);
    }

    function test_swapExactIn_2Hops() public {
        uint256 amountIn = 1 ether;
        uint256 expectedAmountOut = 984211133872795298;

        tokenPath.push(currency0);
        tokenPath.push(currency1);
        tokenPath.push(currency2);
        IV4Router.ExactInputParams memory params = _getExactInputParams(tokenPath, amountIn);

        plan = plan.add(Actions.SWAP_EXACT_IN, abi.encode(params));

        uint256 intermediateBalanceBefore = currency1.balanceOfSelf();

        (uint256 inputBalanceBefore, uint256 outputBalanceBefore, uint256 inputBalanceAfter, uint256 outputBalanceAfter)
        = _finalizeAndExecuteSwap(currency0, currency2, amountIn);

        // check intermediate token balances
        assertEq(intermediateBalanceBefore, currency1.balanceOfSelf());
        assertEq(currency0.balanceOf(address(router)), 0);
        assertEq(currency1.balanceOf(address(router)), 0);
        assertEq(currency2.balanceOf(address(router)), 0);

        assertEq(inputBalanceBefore - inputBalanceAfter, amountIn);
        assertEq(outputBalanceAfter - outputBalanceBefore, expectedAmountOut);
    }

    function test_swapExactIn_3Hops() public {
        uint256 amountIn = 1 ether;
        uint256 expectedAmountOut = 976467664490096191;

        tokenPath.push(currency0);
        tokenPath.push(currency1);
        tokenPath.push(currency2);
        tokenPath.push(currency3);
        IV4Router.ExactInputParams memory params = _getExactInputParams(tokenPath, amountIn);

        plan = plan.add(Actions.SWAP_EXACT_IN, abi.encode(params));

        (uint256 inputBalanceBefore, uint256 outputBalanceBefore, uint256 inputBalanceAfter, uint256 outputBalanceAfter)
        = _finalizeAndExecuteSwap(currency0, currency3, amountIn);

        // check intermediate tokens werent left in the router
        assertEq(currency0.balanceOf(address(router)), 0);
        assertEq(currency1.balanceOf(address(router)), 0);
        assertEq(currency2.balanceOf(address(router)), 0);
        assertEq(currency3.balanceOf(address(router)), 0);

        assertEq(inputBalanceBefore - inputBalanceAfter, amountIn);
        assertEq(outputBalanceAfter - outputBalanceBefore, expectedAmountOut);
    }

    /*//////////////////////////////////////////////////////////////
                ETH -> ERC20 and ERC20 -> ETH EXACT INPUT
    //////////////////////////////////////////////////////////////*/

    function test_nativeIn_swapExactInputSingle() public {
        uint256 amountIn = 1 ether;
        uint256 expectedAmountOut = 992054607780215625;

        IV4Router.ExactInputSingleParams memory params =
            IV4Router.ExactInputSingleParams(nativeKey, true, uint128(amountIn), 0, 0, bytes(""));

        plan = plan.add(Actions.SWAP_EXACT_IN_SINGLE, abi.encode(params));

        (uint256 inputBalanceBefore, uint256 outputBalanceBefore, uint256 inputBalanceAfter, uint256 outputBalanceAfter)
        = _finalizeAndExecuteSwap(nativeKey.currency0, nativeKey.currency1, amountIn);

        assertEq(nativeKey.currency0.balanceOf(address(router)), 0);
        assertEq(nativeKey.currency1.balanceOf(address(router)), 0);

        assertEq(inputBalanceBefore - inputBalanceAfter, amountIn);
        assertEq(outputBalanceAfter - outputBalanceBefore, expectedAmountOut);
    }

    function test_nativeOut_swapExactInputSingle() public {
        uint256 amountIn = 1 ether;
        uint256 expectedAmountOut = 992054607780215625;

        // native output means we need !zeroForOne
        IV4Router.ExactInputSingleParams memory params =
            IV4Router.ExactInputSingleParams(nativeKey, false, uint128(amountIn), 0, 0, bytes(""));

        plan = plan.add(Actions.SWAP_EXACT_IN_SINGLE, abi.encode(params));

        (uint256 inputBalanceBefore, uint256 outputBalanceBefore, uint256 inputBalanceAfter, uint256 outputBalanceAfter)
        = _finalizeAndExecuteSwap(nativeKey.currency1, nativeKey.currency0, amountIn);

        assertEq(nativeKey.currency0.balanceOf(address(router)), 0);
        assertEq(nativeKey.currency1.balanceOf(address(router)), 0);

        assertEq(inputBalanceBefore - inputBalanceAfter, amountIn);
        assertEq(outputBalanceAfter - outputBalanceBefore, expectedAmountOut);
    }

    function test_nativeIn_swapExactIn_1Hop() public {
        uint256 amountIn = 1 ether;
        uint256 expectedAmountOut = 992054607780215625;

        tokenPath.push(CurrencyLibrary.NATIVE);
        tokenPath.push(nativeKey.currency1);
        IV4Router.ExactInputParams memory params = _getExactInputParams(tokenPath, amountIn);
        plan = plan.add(Actions.SWAP_EXACT_IN, abi.encode(params));

        (uint256 inputBalanceBefore, uint256 outputBalanceBefore, uint256 inputBalanceAfter, uint256 outputBalanceAfter)
        = _finalizeAndExecuteSwap(CurrencyLibrary.NATIVE, nativeKey.currency1, amountIn);

        assertEq(nativeKey.currency0.balanceOf(address(router)), 0);
        assertEq(nativeKey.currency1.balanceOf(address(router)), 0);

        assertEq(inputBalanceBefore - inputBalanceAfter, amountIn);
        assertEq(outputBalanceAfter - outputBalanceBefore, expectedAmountOut);
    }

    function test_nativeOut_swapExactIn_1Hop() public {
        uint256 amountIn = 1 ether;
        uint256 expectedAmountOut = 992054607780215625;

        tokenPath.push(nativeKey.currency1);
        tokenPath.push(CurrencyLibrary.NATIVE);
        IV4Router.ExactInputParams memory params = _getExactInputParams(tokenPath, amountIn);

        plan = plan.add(Actions.SWAP_EXACT_IN, abi.encode(params));

        (uint256 inputBalanceBefore, uint256 outputBalanceBefore, uint256 inputBalanceAfter, uint256 outputBalanceAfter)
        = _finalizeAndExecuteSwap(nativeKey.currency1, CurrencyLibrary.NATIVE, amountIn);

        assertEq(nativeKey.currency0.balanceOf(address(router)), 0);
        assertEq(nativeKey.currency1.balanceOf(address(router)), 0);

        assertEq(inputBalanceBefore - inputBalanceAfter, amountIn);
        assertEq(outputBalanceAfter - outputBalanceBefore, expectedAmountOut);
    }

    function test_nativeIn_swapExactIn_2Hops() public {
        uint256 amountIn = 1 ether;
        uint256 expectedAmountOut = 984211133872795298;

        // the initialized nativeKey is (native, currency0)
        tokenPath.push(CurrencyLibrary.NATIVE);
        tokenPath.push(currency0);
        tokenPath.push(currency1);
        IV4Router.ExactInputParams memory params = _getExactInputParams(tokenPath, amountIn);

        plan = plan.add(Actions.SWAP_EXACT_IN, abi.encode(params));

        uint256 intermediateBalanceBefore = currency0.balanceOfSelf();

        (uint256 inputBalanceBefore, uint256 outputBalanceBefore, uint256 inputBalanceAfter, uint256 outputBalanceAfter)
        = _finalizeAndExecuteSwap(CurrencyLibrary.NATIVE, currency1, amountIn);

        // check intermediate token balances
        assertEq(intermediateBalanceBefore, currency0.balanceOfSelf());

        assertEq(nativeKey.currency0.balanceOf(address(router)), 0);
        assertEq(nativeKey.currency1.balanceOf(address(router)), 0);
        assertEq(currency1.balanceOf(address(router)), 0);

        assertEq(inputBalanceBefore - inputBalanceAfter, amountIn);
        assertEq(outputBalanceAfter - outputBalanceBefore, expectedAmountOut);
    }

    function test_nativeOut_swapExactIn_2Hops() public {
        uint256 amountIn = 1 ether;
        uint256 expectedAmountOut = 984211133872795298;

        // the initialized nativeKey is (native, currency0)
        tokenPath.push(currency1);
        tokenPath.push(currency0);
        tokenPath.push(CurrencyLibrary.NATIVE);
        IV4Router.ExactInputParams memory params = _getExactInputParams(tokenPath, amountIn);

        plan = plan.add(Actions.SWAP_EXACT_IN, abi.encode(params));

        uint256 intermediateBalanceBefore = currency0.balanceOfSelf();

        (uint256 inputBalanceBefore, uint256 outputBalanceBefore, uint256 inputBalanceAfter, uint256 outputBalanceAfter)
        = _finalizeAndExecuteSwap(currency1, CurrencyLibrary.NATIVE, amountIn);

        // check intermediate token balances
        assertEq(intermediateBalanceBefore, currency0.balanceOfSelf());
        assertEq(nativeKey.currency0.balanceOf(address(router)), 0);
        assertEq(nativeKey.currency1.balanceOf(address(router)), 0);
        assertEq(currency1.balanceOf(address(router)), 0);

        assertEq(inputBalanceBefore - inputBalanceAfter, amountIn);
        assertEq(outputBalanceAfter - outputBalanceBefore, expectedAmountOut);
    }

    /*//////////////////////////////////////////////////////////////å
                        ERC20 -> ERC20 EXACT OUTPUT
    //////////////////////////////////////////////////////////////*/

    function test_swapExactOutputSingle_zeroForOne() public {
        uint256 amountOut = 1 ether;
        uint256 expectedAmountIn = 1008049273448486163;

        IV4Router.ExactOutputSingleParams memory params =
            IV4Router.ExactOutputSingleParams(key0, true, uint128(amountOut), 0, 0, bytes(""));

        plan = plan.add(Actions.SWAP_EXACT_OUT_SINGLE, abi.encode(params));

        (uint256 inputBalanceBefore, uint256 outputBalanceBefore, uint256 inputBalanceAfter, uint256 outputBalanceAfter)
        = _finalizeAndExecuteSwap(key0.currency0, key0.currency1, expectedAmountIn);

        assertEq(currency0.balanceOf(address(router)), 0);
        assertEq(currency1.balanceOf(address(router)), 0);

        assertEq(inputBalanceBefore - inputBalanceAfter, expectedAmountIn);
        assertEq(outputBalanceAfter - outputBalanceBefore, amountOut);
    }

    function test_swapExactOutputSingle_oneForZero() public {
        uint256 amountOut = 1 ether;
        uint256 expectedAmountIn = 1008049273448486163;

        IV4Router.ExactOutputSingleParams memory params =
            IV4Router.ExactOutputSingleParams(key0, false, uint128(amountOut), 0, 0, bytes(""));

        plan = plan.add(Actions.SWAP_EXACT_OUT_SINGLE, abi.encode(params));

        (uint256 inputBalanceBefore, uint256 outputBalanceBefore, uint256 inputBalanceAfter, uint256 outputBalanceAfter)
        = _finalizeAndExecuteSwap(key0.currency1, key0.currency0, expectedAmountIn);

        assertEq(currency0.balanceOf(address(router)), 0);
        assertEq(currency1.balanceOf(address(router)), 0);

        assertEq(inputBalanceBefore - inputBalanceAfter, expectedAmountIn);
        assertEq(outputBalanceAfter - outputBalanceBefore, amountOut);
    }

    function test_swapExactOut_1Hop_zeroForOne() public {
        uint256 amountOut = 1 ether;
        uint256 expectedAmountIn = 1008049273448486163;

        tokenPath.push(currency0);
        tokenPath.push(currency1);
        IV4Router.ExactOutputParams memory params = _getExactOutputParams(tokenPath, amountOut);

        plan = plan.add(Actions.SWAP_EXACT_OUT, abi.encode(params));

        (uint256 inputBalanceBefore, uint256 outputBalanceBefore, uint256 inputBalanceAfter, uint256 outputBalanceAfter)
        = _finalizeAndExecuteSwap(key0.currency0, key0.currency1, expectedAmountIn);

        assertEq(currency0.balanceOf(address(router)), 0);
        assertEq(currency1.balanceOf(address(router)), 0);

        assertEq(inputBalanceBefore - inputBalanceAfter, expectedAmountIn);
        assertEq(outputBalanceAfter - outputBalanceBefore, amountOut);
    }

    function test_swapExactOut_1Hop_oneForZero() public {
        uint256 amountOut = 1 ether;
        uint256 expectedAmountIn = 1008049273448486163;

        tokenPath.push(currency1);
        tokenPath.push(currency0);
        IV4Router.ExactOutputParams memory params = _getExactOutputParams(tokenPath, amountOut);

        plan = plan.add(Actions.SWAP_EXACT_OUT, abi.encode(params));

        (uint256 inputBalanceBefore, uint256 outputBalanceBefore, uint256 inputBalanceAfter, uint256 outputBalanceAfter)
        = _finalizeAndExecuteSwap(currency1, currency0, expectedAmountIn);

        assertEq(currency0.balanceOf(address(router)), 0);
        assertEq(currency1.balanceOf(address(router)), 0);

        assertEq(inputBalanceBefore - inputBalanceAfter, expectedAmountIn);
        assertEq(outputBalanceAfter - outputBalanceBefore, amountOut);
    }

    function test_swapExactOut_2Hops() public {
        uint256 amountOut = 1 ether;
        uint256 expectedAmountIn = 1016204441757464409;

        tokenPath.push(currency0);
        tokenPath.push(currency1);
        tokenPath.push(currency2);
        IV4Router.ExactOutputParams memory params = _getExactOutputParams(tokenPath, amountOut);

        uint256 intermediateBalanceBefore = currency1.balanceOfSelf();

        plan = plan.add(Actions.SWAP_EXACT_OUT, abi.encode(params));

        (uint256 inputBalanceBefore, uint256 outputBalanceBefore, uint256 inputBalanceAfter, uint256 outputBalanceAfter)
        = _finalizeAndExecuteSwap(currency0, currency2, expectedAmountIn);

        assertEq(intermediateBalanceBefore, currency1.balanceOfSelf());
        assertEq(currency0.balanceOf(address(router)), 0);
        assertEq(currency1.balanceOf(address(router)), 0);
        assertEq(currency2.balanceOf(address(router)), 0);

        assertEq(inputBalanceBefore - inputBalanceAfter, expectedAmountIn);
        assertEq(outputBalanceAfter - outputBalanceBefore, amountOut);
    }

    function test_swapExactOut_3Hops() public {
        uint256 amountOut = 1 ether;
        uint256 expectedAmountIn = 1024467570922834110;

        tokenPath.push(currency0);
        tokenPath.push(currency1);
        tokenPath.push(currency2);
        tokenPath.push(currency3);
        IV4Router.ExactOutputParams memory params = _getExactOutputParams(tokenPath, amountOut);

        plan = plan.add(Actions.SWAP_EXACT_OUT, abi.encode(params));

        (uint256 inputBalanceBefore, uint256 outputBalanceBefore, uint256 inputBalanceAfter, uint256 outputBalanceAfter)
        = _finalizeAndExecuteSwap(currency0, currency3, expectedAmountIn);

        assertEq(currency0.balanceOf(address(router)), 0);
        assertEq(currency1.balanceOf(address(router)), 0);
        assertEq(currency2.balanceOf(address(router)), 0);
        assertEq(currency3.balanceOf(address(router)), 0);

        assertEq(inputBalanceBefore - inputBalanceAfter, expectedAmountIn);
        assertEq(outputBalanceAfter - outputBalanceBefore, amountOut);
    }

    /*//////////////////////////////////////////////////////////////
                ETH -> ERC20 and ERC20 -> ETH EXACT OUTPUT
    //////////////////////////////////////////////////////////////*/

    function test_nativeIn_swapExactOutputSingle_sweepExcessETH() public {
        uint256 amountOut = 1 ether;
        uint256 expectedAmountIn = 1008049273448486163;

        IV4Router.ExactOutputSingleParams memory params =
            IV4Router.ExactOutputSingleParams(nativeKey, true, uint128(amountOut), 0, 0, bytes(""));

        plan = plan.add(Actions.SWAP_EXACT_OUT_SINGLE, abi.encode(params));

        (uint256 inputBalanceBefore, uint256 outputBalanceBefore, uint256 inputBalanceAfter, uint256 outputBalanceAfter)
        = _finalizeAndExecuteNativeInputExactOutputSwap(nativeKey.currency0, nativeKey.currency1, expectedAmountIn);

        assertEq(nativeKey.currency0.balanceOf(address(router)), 0);
        assertEq(nativeKey.currency1.balanceOf(address(router)), 0);

        assertEq(inputBalanceBefore - inputBalanceAfter, expectedAmountIn);
        assertEq(outputBalanceAfter - outputBalanceBefore, amountOut);
    }

    function test_nativeOut_swapExactOutputSingle() public {
        uint256 amountOut = 1 ether;
        uint256 expectedAmountIn = 1008049273448486163;

        IV4Router.ExactOutputSingleParams memory params =
            IV4Router.ExactOutputSingleParams(nativeKey, false, uint128(amountOut), 0, 0, bytes(""));

        plan = plan.add(Actions.SWAP_EXACT_OUT_SINGLE, abi.encode(params));

        (uint256 inputBalanceBefore, uint256 outputBalanceBefore, uint256 inputBalanceAfter, uint256 outputBalanceAfter)
        = _finalizeAndExecuteSwap(nativeKey.currency1, nativeKey.currency0, expectedAmountIn);

        assertEq(nativeKey.currency0.balanceOf(address(router)), 0);
        assertEq(nativeKey.currency1.balanceOf(address(router)), 0);

        assertEq(inputBalanceBefore - inputBalanceAfter, expectedAmountIn);
        assertEq(outputBalanceAfter - outputBalanceBefore, amountOut);
    }

    function test_nativeIn_swapExactOut_1Hop_sweepExcessETH() public {
        uint256 amountOut = 1 ether;
        uint256 expectedAmountIn = 1008049273448486163;

        tokenPath.push(CurrencyLibrary.NATIVE);
        tokenPath.push(nativeKey.currency1);
        IV4Router.ExactOutputParams memory params = _getExactOutputParams(tokenPath, amountOut);

        plan = plan.add(Actions.SWAP_EXACT_OUT, abi.encode(params));

        (uint256 inputBalanceBefore, uint256 outputBalanceBefore, uint256 inputBalanceAfter, uint256 outputBalanceAfter)
        = _finalizeAndExecuteNativeInputExactOutputSwap(CurrencyLibrary.NATIVE, nativeKey.currency1, expectedAmountIn);

        assertEq(nativeKey.currency0.balanceOf(address(router)), 0);
        assertEq(nativeKey.currency1.balanceOf(address(router)), 0);

        assertEq(inputBalanceBefore - inputBalanceAfter, expectedAmountIn);
        assertEq(outputBalanceAfter - outputBalanceBefore, amountOut);
    }

    function test_nativeOut_swapExactOut_1Hop() public {
        uint256 amountOut = 1 ether;
        uint256 expectedAmountIn = 1008049273448486163;

        tokenPath.push(nativeKey.currency1);
        tokenPath.push(CurrencyLibrary.NATIVE);
        IV4Router.ExactOutputParams memory params = _getExactOutputParams(tokenPath, amountOut);

        plan = plan.add(Actions.SWAP_EXACT_OUT, abi.encode(params));

        (uint256 inputBalanceBefore, uint256 outputBalanceBefore, uint256 inputBalanceAfter, uint256 outputBalanceAfter)
        = _finalizeAndExecuteSwap(nativeKey.currency1, CurrencyLibrary.NATIVE, expectedAmountIn);

        assertEq(nativeKey.currency0.balanceOf(address(router)), 0);
        assertEq(nativeKey.currency1.balanceOf(address(router)), 0);

        assertEq(inputBalanceBefore - inputBalanceAfter, expectedAmountIn);
        assertEq(outputBalanceAfter - outputBalanceBefore, amountOut);
    }

    function test_nativeIn_swapExactOut_2Hops_sweepExcessETH() public {
        uint256 amountOut = 1 ether;
        uint256 expectedAmountIn = 1016204441757464409;

        // the initialized nativeKey is (native, currency0)
        tokenPath.push(CurrencyLibrary.NATIVE);
        tokenPath.push(currency0);
        tokenPath.push(currency1);
        IV4Router.ExactOutputParams memory params = _getExactOutputParams(tokenPath, amountOut);

        uint256 intermediateBalanceBefore = currency0.balanceOfSelf();

        plan = plan.add(Actions.SWAP_EXACT_OUT, abi.encode(params));

        (uint256 inputBalanceBefore, uint256 outputBalanceBefore, uint256 inputBalanceAfter, uint256 outputBalanceAfter)
        = _finalizeAndExecuteNativeInputExactOutputSwap(CurrencyLibrary.NATIVE, currency1, expectedAmountIn);

        assertEq(intermediateBalanceBefore, currency0.balanceOfSelf());
        assertEq(currency1.balanceOf(address(router)), 0);
        assertEq(currency0.balanceOf(address(router)), 0);
        assertEq(CurrencyLibrary.NATIVE.balanceOf(address(router)), 0);

        assertEq(inputBalanceBefore - inputBalanceAfter, expectedAmountIn);
        assertEq(outputBalanceAfter - outputBalanceBefore, amountOut);
    }
}
