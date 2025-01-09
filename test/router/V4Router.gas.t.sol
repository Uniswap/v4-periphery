// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";

import {IV4Router} from "../../src/interfaces/IV4Router.sol";
import {RoutingTestHelpers} from "../shared/RoutingTestHelpers.sol";
import {Planner} from "../shared/Planner.sol";
import {Actions} from "../../src/libraries/Actions.sol";
import {ActionConstants} from "../../src/libraries/ActionConstants.sol";

contract V4RouterTest is RoutingTestHelpers {
    function setUp() public {
        setupRouterCurrenciesAndPoolsWithLiquidity();
        plan = Planner.init();
    }

    function test_gas_bytecodeSize() public {
        vm.snapshotValue("V4Router_Bytecode", address(router).code.length);
    }

    function test_router_initcodeHash() public {
        vm.snapshotValue(
            "router initcode hash (without constructor params, as uint256)",
            uint256(keccak256(abi.encodePacked(vm.getCode("MockV4Router.sol:MockV4Router"))))
        );
    }

    /*//////////////////////////////////////////////////////////////
                        ERC20 -> ERC20 EXACT INPUT
    //////////////////////////////////////////////////////////////*/

    function test_gas_swapExactInputSingle_zeroForOne() public {
        uint256 amountIn = 1 ether;

        IV4Router.ExactInputSingleParams memory params =
            IV4Router.ExactInputSingleParams(key0, true, uint128(amountIn), 0, bytes(""));

        plan = plan.add(Actions.SWAP_EXACT_IN_SINGLE, abi.encode(params));
        bytes memory data = plan.finalizeSwap(key0.currency0, key0.currency1, ActionConstants.MSG_SENDER);

        router.executeActions(data);
        vm.snapshotGasLastCall("V4Router_ExactInputSingle");
    }

    function test_gas_swapExactIn_1Hop_zeroForOne() public {
        uint256 amountIn = 1 ether;

        tokenPath.push(currency0);
        tokenPath.push(currency1);
        IV4Router.ExactInputParams memory params = _getExactInputParams(tokenPath, amountIn);

        plan = plan.add(Actions.SWAP_EXACT_IN, abi.encode(params));
        bytes memory data = plan.finalizeSwap(currency0, currency1, ActionConstants.MSG_SENDER);

        router.executeActions(data);
        vm.snapshotGasLastCall("V4Router_ExactIn1Hop_zeroForOne");
    }

    function test_gas_swapExactIn_1Hop_oneForZero() public {
        uint256 amountIn = 1 ether;

        tokenPath.push(currency1);
        tokenPath.push(currency0);
        IV4Router.ExactInputParams memory params = _getExactInputParams(tokenPath, amountIn);

        plan = plan.add(Actions.SWAP_EXACT_IN, abi.encode(params));
        bytes memory data = plan.finalizeSwap(currency1, currency0, ActionConstants.MSG_SENDER);

        router.executeActions(data);
        vm.snapshotGasLastCall("V4Router_ExactIn1Hop_oneForZero");
    }

    function test_gas_swapExactIn_2Hops() public {
        uint256 amountIn = 1 ether;

        tokenPath.push(currency0);
        tokenPath.push(currency1);
        tokenPath.push(currency2);
        IV4Router.ExactInputParams memory params = _getExactInputParams(tokenPath, amountIn);

        plan = plan.add(Actions.SWAP_EXACT_IN, abi.encode(params));
        bytes memory data = plan.finalizeSwap(currency0, currency2, ActionConstants.MSG_SENDER);

        router.executeActions(data);
        vm.snapshotGasLastCall("V4Router_ExactIn2Hops");
    }

    function test_gas_swapExactIn_3Hops() public {
        uint256 amountIn = 1 ether;

        tokenPath.push(currency0);
        tokenPath.push(currency1);
        tokenPath.push(currency2);
        tokenPath.push(currency3);
        IV4Router.ExactInputParams memory params = _getExactInputParams(tokenPath, amountIn);

        plan = plan.add(Actions.SWAP_EXACT_IN, abi.encode(params));
        bytes memory data = plan.finalizeSwap(currency0, currency3, ActionConstants.MSG_SENDER);

        router.executeActions(data);
        vm.snapshotGasLastCall("V4Router_ExactIn3Hops");
    }

    /*//////////////////////////////////////////////////////////////
                ETH -> ERC20 and ERC20 -> ETH EXACT INPUT
    //////////////////////////////////////////////////////////////*/

    function test_gas_nativeIn_swapExactInputSingle() public {
        uint256 amountIn = 1 ether;

        IV4Router.ExactInputSingleParams memory params =
            IV4Router.ExactInputSingleParams(nativeKey, true, uint128(amountIn), 0, bytes(""));

        plan = plan.add(Actions.SWAP_EXACT_IN_SINGLE, abi.encode(params));
        bytes memory data = plan.finalizeSwap(nativeKey.currency0, nativeKey.currency1, ActionConstants.MSG_SENDER);

        router.executeActions{value: amountIn}(data);
        vm.snapshotGasLastCall("V4Router_ExactInputSingle_nativeIn");
    }

    function test_gas_nativeOut_swapExactInputSingle() public {
        uint256 amountIn = 1 ether;

        IV4Router.ExactInputSingleParams memory params =
            IV4Router.ExactInputSingleParams(nativeKey, false, uint128(amountIn), 0, bytes(""));

        plan = plan.add(Actions.SWAP_EXACT_IN_SINGLE, abi.encode(params));
        bytes memory data = plan.finalizeSwap(nativeKey.currency1, nativeKey.currency0, ActionConstants.MSG_SENDER);

        router.executeActions(data);
        vm.snapshotGasLastCall("V4Router_ExactInputSingle_nativeOut");
    }

    function test_gas_nativeIn_swapExactIn_1Hop() public {
        uint256 amountIn = 1 ether;

        tokenPath.push(CurrencyLibrary.ADDRESS_ZERO);
        tokenPath.push(currency0);
        IV4Router.ExactInputParams memory params = _getExactInputParams(tokenPath, amountIn);

        plan = plan.add(Actions.SWAP_EXACT_IN, abi.encode(params));
        bytes memory data = plan.finalizeSwap(CurrencyLibrary.ADDRESS_ZERO, currency0, ActionConstants.MSG_SENDER);

        router.executeActions{value: amountIn}(data);
        vm.snapshotGasLastCall("V4Router_ExactIn1Hop_nativeIn");
    }

    function test_gas_nativeOut_swapExactIn_1Hop() public {
        uint256 amountIn = 1 ether;

        tokenPath.push(currency0);
        tokenPath.push(CurrencyLibrary.ADDRESS_ZERO);
        IV4Router.ExactInputParams memory params = _getExactInputParams(tokenPath, amountIn);

        plan = plan.add(Actions.SWAP_EXACT_IN, abi.encode(params));
        bytes memory data = plan.finalizeSwap(currency0, CurrencyLibrary.ADDRESS_ZERO, ActionConstants.MSG_SENDER);

        router.executeActions(data);
        vm.snapshotGasLastCall("V4Router_ExactIn1Hop_nativeOut");
    }

    function test_gas_nativeIn_swapExactIn_2Hops() public {
        uint256 amountIn = 1 ether;

        tokenPath.push(CurrencyLibrary.ADDRESS_ZERO);
        tokenPath.push(currency0);
        tokenPath.push(currency1);
        IV4Router.ExactInputParams memory params = _getExactInputParams(tokenPath, amountIn);

        plan = plan.add(Actions.SWAP_EXACT_IN, abi.encode(params));
        bytes memory data = plan.finalizeSwap(CurrencyLibrary.ADDRESS_ZERO, currency1, ActionConstants.MSG_SENDER);

        router.executeActions{value: amountIn}(data);
        vm.snapshotGasLastCall("V4Router_ExactIn2Hops_nativeIn");
    }

    function test_gas_nativeIn_swapExactIn_3Hops() public {
        uint256 amountIn = 1 ether;

        tokenPath.push(CurrencyLibrary.ADDRESS_ZERO);
        tokenPath.push(currency0);
        tokenPath.push(currency1);
        tokenPath.push(currency2);
        IV4Router.ExactInputParams memory params = _getExactInputParams(tokenPath, amountIn);

        plan = plan.add(Actions.SWAP_EXACT_IN, abi.encode(params));
        bytes memory data = plan.finalizeSwap(CurrencyLibrary.ADDRESS_ZERO, currency2, ActionConstants.MSG_SENDER);

        router.executeActions{value: amountIn}(data);
        vm.snapshotGasLastCall("V4Router_ExactIn3Hops_nativeIn");
    }

    /*//////////////////////////////////////////////////////////////
                        ERC20 -> ERC20 EXACT OUTPUT
    //////////////////////////////////////////////////////////////*/

    function test_gas_swapExactOutputSingle_zeroForOne() public {
        uint256 amountOut = 1 ether;

        IV4Router.ExactOutputSingleParams memory params =
            IV4Router.ExactOutputSingleParams(key0, true, uint128(amountOut), type(uint128).max, bytes(""));

        plan = plan.add(Actions.SWAP_EXACT_OUT_SINGLE, abi.encode(params));
        bytes memory data = plan.finalizeSwap(key0.currency0, key0.currency1, ActionConstants.MSG_SENDER);

        router.executeActions(data);
        vm.snapshotGasLastCall("V4Router_ExactOutputSingle");
    }

    function test_gas_swapExactOut_1Hop_zeroForOne() public {
        uint256 amountOut = 1 ether;

        tokenPath.push(currency0);
        tokenPath.push(currency1);
        IV4Router.ExactOutputParams memory params = _getExactOutputParams(tokenPath, amountOut);

        plan = plan.add(Actions.SWAP_EXACT_OUT, abi.encode(params));
        bytes memory data = plan.finalizeSwap(currency0, currency1, ActionConstants.MSG_SENDER);

        router.executeActions(data);
        vm.snapshotGasLastCall("V4Router_ExactOut1Hop_zeroForOne");
    }

    function test_gas_swapExactOut_1Hop_oneForZero() public {
        uint256 amountOut = 1 ether;

        tokenPath.push(currency1);
        tokenPath.push(currency0);
        IV4Router.ExactOutputParams memory params = _getExactOutputParams(tokenPath, amountOut);

        plan = plan.add(Actions.SWAP_EXACT_OUT, abi.encode(params));
        bytes memory data = plan.finalizeSwap(currency1, currency0, ActionConstants.MSG_SENDER);

        router.executeActions(data);
        vm.snapshotGasLastCall("V4Router_ExactOut1Hop_oneForZero");
    }

    function test_gas_swapExactOut_2Hops() public {
        uint256 amountOut = 1 ether;

        tokenPath.push(currency0);
        tokenPath.push(currency1);
        tokenPath.push(currency2);
        IV4Router.ExactOutputParams memory params = _getExactOutputParams(tokenPath, amountOut);

        plan = plan.add(Actions.SWAP_EXACT_OUT, abi.encode(params));
        bytes memory data = plan.finalizeSwap(currency0, currency2, ActionConstants.MSG_SENDER);

        router.executeActions(data);
        vm.snapshotGasLastCall("V4Router_ExactOut2Hops");
    }

    function test_gas_swapExactOut_3Hops() public {
        uint256 amountOut = 1 ether;

        tokenPath.push(currency0);
        tokenPath.push(currency1);
        tokenPath.push(currency2);
        tokenPath.push(currency3);
        IV4Router.ExactOutputParams memory params = _getExactOutputParams(tokenPath, amountOut);

        plan = plan.add(Actions.SWAP_EXACT_OUT, abi.encode(params));
        bytes memory data = plan.finalizeSwap(currency0, currency3, ActionConstants.MSG_SENDER);

        router.executeActions(data);
        vm.snapshotGasLastCall("V4Router_ExactOut3Hops");
    }

    /*//////////////////////////////////////////////////////////////
                ETH -> ERC20 and ERC20 -> ETH EXACT OUTPUT
    //////////////////////////////////////////////////////////////*/

    function test_gas_nativeIn_swapExactOutputSingle_sweepExcessETH() public {
        uint256 amountOut = 1 ether;

        IV4Router.ExactOutputSingleParams memory params =
            IV4Router.ExactOutputSingleParams(nativeKey, true, uint128(amountOut), type(uint128).max, bytes(""));

        plan = plan.add(Actions.SWAP_EXACT_OUT_SINGLE, abi.encode(params));
        bytes memory data = plan.finalizeSwap(nativeKey.currency0, nativeKey.currency1, ActionConstants.MSG_SENDER);

        router.executeActionsAndSweepExcessETH{value: 2 ether}(data);
        vm.snapshotGasLastCall("V4Router_ExactOutputSingle_nativeIn_sweepETH");
    }

    function test_gas_nativeOut_swapExactOutputSingle() public {
        uint256 amountOut = 1 ether;

        IV4Router.ExactOutputSingleParams memory params =
            IV4Router.ExactOutputSingleParams(nativeKey, false, uint128(amountOut), type(uint128).max, bytes(""));

        plan = plan.add(Actions.SWAP_EXACT_OUT_SINGLE, abi.encode(params));
        bytes memory data = plan.finalizeSwap(nativeKey.currency1, nativeKey.currency0, ActionConstants.MSG_SENDER);

        router.executeActionsAndSweepExcessETH(data);
        vm.snapshotGasLastCall("V4Router_ExactOutputSingle_nativeOut");
    }

    function test_gas_nativeIn_swapExactOut_1Hop_sweepExcessETH() public {
        uint256 amountOut = 1 ether;

        tokenPath.push(CurrencyLibrary.ADDRESS_ZERO);
        tokenPath.push(currency0);
        IV4Router.ExactOutputParams memory params = _getExactOutputParams(tokenPath, amountOut);

        plan = plan.add(Actions.SWAP_EXACT_OUT, abi.encode(params));
        bytes memory data = plan.finalizeSwap(CurrencyLibrary.ADDRESS_ZERO, currency0, ActionConstants.MSG_SENDER);

        router.executeActionsAndSweepExcessETH{value: 2 ether}(data);
        vm.snapshotGasLastCall("V4Router_ExactOut1Hop_nativeIn_sweepETH");
    }

    function test_gas_nativeOut_swapExactOut_1Hop() public {
        uint256 amountOut = 1 ether;

        tokenPath.push(currency0);
        tokenPath.push(CurrencyLibrary.ADDRESS_ZERO);
        IV4Router.ExactOutputParams memory params = _getExactOutputParams(tokenPath, amountOut);

        plan = plan.add(Actions.SWAP_EXACT_OUT, abi.encode(params));
        bytes memory data = plan.finalizeSwap(currency0, CurrencyLibrary.ADDRESS_ZERO, ActionConstants.MSG_SENDER);

        router.executeActions(data);
        vm.snapshotGasLastCall("V4Router_ExactOut1Hop_nativeOut");
    }

    function test_gas_nativeIn_swapExactOut_2Hops_sweepExcessETH() public {
        uint256 amountOut = 1 ether;

        tokenPath.push(CurrencyLibrary.ADDRESS_ZERO);
        tokenPath.push(currency0);
        tokenPath.push(currency1);
        IV4Router.ExactOutputParams memory params = _getExactOutputParams(tokenPath, amountOut);

        plan = plan.add(Actions.SWAP_EXACT_OUT, abi.encode(params));
        bytes memory data = plan.finalizeSwap(CurrencyLibrary.ADDRESS_ZERO, currency1, ActionConstants.MSG_SENDER);

        router.executeActionsAndSweepExcessETH{value: 2 ether}(data);
        vm.snapshotGasLastCall("V4Router_ExactOut2Hops_nativeIn");
    }

    function test_gas_nativeIn_swapExactOut_3Hops_sweepExcessETH() public {
        uint256 amountOut = 1 ether;

        tokenPath.push(CurrencyLibrary.ADDRESS_ZERO);
        tokenPath.push(currency0);
        tokenPath.push(currency1);
        tokenPath.push(currency2);
        IV4Router.ExactOutputParams memory params = _getExactOutputParams(tokenPath, amountOut);

        plan = plan.add(Actions.SWAP_EXACT_OUT, abi.encode(params));
        bytes memory data = plan.finalizeSwap(CurrencyLibrary.ADDRESS_ZERO, currency2, ActionConstants.MSG_SENDER);

        router.executeActionsAndSweepExcessETH{value: 2 ether}(data);
        vm.snapshotGasLastCall("V4Router_ExactOut3Hops_nativeIn");
    }

    function test_gas_nativeOut_swapExactOut_3Hops() public {
        uint256 amountOut = 1 ether;

        tokenPath.push(currency2);
        tokenPath.push(currency1);
        tokenPath.push(currency0);
        tokenPath.push(CurrencyLibrary.ADDRESS_ZERO);

        IV4Router.ExactOutputParams memory params = _getExactOutputParams(tokenPath, amountOut);

        plan = plan.add(Actions.SWAP_EXACT_OUT, abi.encode(params));
        bytes memory data = plan.finalizeSwap(currency2, CurrencyLibrary.ADDRESS_ZERO, ActionConstants.MSG_SENDER);

        router.executeActions(data);
        vm.snapshotGasLastCall("V4Router_ExactOut3Hops_nativeOut");
    }
}
