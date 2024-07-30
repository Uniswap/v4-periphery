// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {GasSnapshot} from "forge-gas-snapshot/GasSnapshot.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";

import {IV4Router} from "../../src/interfaces/IV4Router.sol";
import {RoutingTestHelpers} from "../shared/RoutingTestHelpers.sol";
import {Plan, ActionsRouterPlanner} from "../shared/ActionsRouterPlanner.sol";
import {Actions} from "../../src/libraries/Actions.sol";

contract V4RouterTest is RoutingTestHelpers, GasSnapshot {
    using CurrencyLibrary for Currency;
    using ActionsRouterPlanner for Plan;

    function setUp() public {
        setupRouterCurrenciesAndPoolsWithLiquidity();
        plan = ActionsRouterPlanner.init();
    }

    function test_gas_bytecodeSize() public {
        snapSize("V4Router_Bytecode", address(router));
    }

    function test_gas_swapExactInputSingle_zeroForOne() public {
        uint256 amountIn = 1 ether;

        IV4Router.ExactInputSingleParams memory params =
            IV4Router.ExactInputSingleParams(key0, true, uint128(amountIn), 0, 0, bytes(""));

        plan = plan.add(Actions.SWAP_EXACT_IN_SINGLE, abi.encode(params));
        bytes memory data = plan.finalizeSwap(key0.currency0, key0.currency1, address(this));

        router.executeActions(data);
        snapLastCall("V4Router_ExactInputSingle");
    }

    function test_gas_swapExactIn_1Hop_zeroForOne() public {
        uint256 amountIn = 1 ether;

        tokenPath.push(currency0);
        tokenPath.push(currency1);
        IV4Router.ExactInputParams memory params = _getExactInputParams(tokenPath, amountIn);

        plan = plan.add(Actions.SWAP_EXACT_IN, abi.encode(params));
        bytes memory data = plan.finalizeSwap(currency0, currency1, address(this));

        router.executeActions(data);
        snapLastCall("V4Router_ExactIn1Hop_zeroForOne");
    }

    function test_swapExactIn_1Hop_oneForZero() public {
        uint256 amountIn = 1 ether;

        tokenPath.push(currency1);
        tokenPath.push(currency0);
        IV4Router.ExactInputParams memory params = _getExactInputParams(tokenPath, amountIn);

        plan = plan.add(Actions.SWAP_EXACT_IN, abi.encode(params));
        bytes memory data = plan.finalizeSwap(currency1, currency0, address(this));

        router.executeActions(data);
        snapLastCall("V4Router_ExactIn1Hop_oneForZero");
    }

    function test_gas_swapExactIn_2Hops() public {
        uint256 amountIn = 1 ether;

        tokenPath.push(currency0);
        tokenPath.push(currency1);
        tokenPath.push(currency2);
        IV4Router.ExactInputParams memory params = _getExactInputParams(tokenPath, amountIn);

        plan = plan.add(Actions.SWAP_EXACT_IN, abi.encode(params));
        bytes memory data = plan.finalizeSwap(currency0, currency2, address(this));

        router.executeActions(data);
        snapLastCall("V4Router_ExactIn2Hops");
    }

    function test_gas_swapExactIn_3Hops() public {
        uint256 amountIn = 1 ether;

        tokenPath.push(currency0);
        tokenPath.push(currency1);
        tokenPath.push(currency2);
        tokenPath.push(currency3);
        IV4Router.ExactInputParams memory params = _getExactInputParams(tokenPath, amountIn);

        plan = plan.add(Actions.SWAP_EXACT_IN, abi.encode(params));
        bytes memory data = plan.finalizeSwap(currency0, currency3, address(this));

        router.executeActions(data);
        snapLastCall("V4Router_ExactIn3Hops");
    }

    function test_gas_swapExactOutputSingle_zeroForOne() public {
        uint256 amountOut = 1 ether;

        IV4Router.ExactOutputSingleParams memory params =
            IV4Router.ExactOutputSingleParams(key0, true, uint128(amountOut), 0, 0, bytes(""));

        plan = plan.add(Actions.SWAP_EXACT_OUT_SINGLE, abi.encode(params));
        bytes memory data = plan.finalizeSwap(key0.currency0, key0.currency1, address(this));

        router.executeActions(data);
        snapLastCall("V4Router_ExactOutputSingle");
    }

    function test_gas_swapExactOut_1Hop_zeroForOne() public {
        uint256 amountOut = 1 ether;

        tokenPath.push(currency0);
        tokenPath.push(currency1);
        IV4Router.ExactOutputParams memory params = _getExactOutputParams(tokenPath, amountOut);

        plan = plan.add(Actions.SWAP_EXACT_OUT, abi.encode(params));
        bytes memory data = plan.finalizeSwap(currency0, currency1, address(this));

        router.executeActions(data);
        snapLastCall("V4Router_ExactOut1Hop_zeroForOne");
    }

    function test_gas_swapExactOut_1Hop_oneForZero() public {
        uint256 amountOut = 1 ether;

        tokenPath.push(currency1);
        tokenPath.push(currency0);
        IV4Router.ExactOutputParams memory params = _getExactOutputParams(tokenPath, amountOut);

        plan = plan.add(Actions.SWAP_EXACT_OUT, abi.encode(params));
        bytes memory data = plan.finalizeSwap(currency1, currency0, address(this));

        router.executeActions(data);
        snapLastCall("V4Router_ExactOut1Hop_oneForZero");
    }

    function test_gas_swapExactOut_2Hops() public {
        uint256 amountOut = 1 ether;

        tokenPath.push(currency0);
        tokenPath.push(currency1);
        tokenPath.push(currency2);
        IV4Router.ExactOutputParams memory params = _getExactOutputParams(tokenPath, amountOut);

        plan = plan.add(Actions.SWAP_EXACT_OUT, abi.encode(params));
        bytes memory data = plan.finalizeSwap(currency0, currency2, address(this));

        router.executeActions(data);
        snapLastCall("V4Router_ExactOut2Hops");
    }

    function test_gas_swapExactOut_3Hops() public {
        uint256 amountOut = 1 ether;

        tokenPath.push(currency0);
        tokenPath.push(currency1);
        tokenPath.push(currency2);
        tokenPath.push(currency3);
        IV4Router.ExactOutputParams memory params = _getExactOutputParams(tokenPath, amountOut);

        plan = plan.add(Actions.SWAP_EXACT_OUT, abi.encode(params));
        bytes memory data = plan.finalizeSwap(currency0, currency3, address(this));

        router.executeActions(data);
        snapLastCall("V4Router_ExactOut3Hops");
    }
}
