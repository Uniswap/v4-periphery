// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {GasSnapshot} from "forge-gas-snapshot/GasSnapshot.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";

import {IV4Router} from "../../src/interfaces/IV4Router.sol";
import {RoutingTestHelpers} from "../shared/RoutingTestHelpers.sol";
import {Plan, Planner} from "../shared/Planner.sol";
import {Actions} from "../../src/libraries/Actions.sol";
import {ActionConstants} from "../../src/libraries/ActionConstants.sol";

contract PaymentsTests is RoutingTestHelpers, GasSnapshot {
    using CurrencyLibrary for Currency;
    using Planner for Plan;

    function setUp() public {
        setupRouterCurrenciesAndPoolsWithLiquidity();
        plan = Planner.init();
    }

    function test_gas_swap_settleFromCaller_takeAllToSpecifiedAddress() public {
        uint256 amountIn = 1 ether;
        IV4Router.ExactInputSingleParams memory params =
            IV4Router.ExactInputSingleParams(key0, true, uint128(amountIn), 0, 0, bytes(""));

        plan = plan.add(Actions.SWAP_EXACT_IN_SINGLE, abi.encode(params));
        plan = plan.add(Actions.SETTLE_ALL, abi.encode(key0.currency0, MAX_SETTLE_AMOUNT));
        plan = plan.add(Actions.TAKE, abi.encode(key0.currency1, address(this), ActionConstants.OPEN_DELTA));

        bytes memory data = plan.encode();
        router.executeActions(data);
        snapLastCall("Payments_swap_settleFromCaller_takeAllToSpecifiedAddress");
    }

    function test_gas_swap_settleFromCaller_takeAllToMsgSender() public {
        uint256 amountIn = 1 ether;
        IV4Router.ExactInputSingleParams memory params =
            IV4Router.ExactInputSingleParams(key0, true, uint128(amountIn), 0, 0, bytes(""));

        plan = plan.add(Actions.SWAP_EXACT_IN_SINGLE, abi.encode(params));
        plan = plan.add(Actions.SETTLE_TAKE_PAIR, abi.encode(key0.currency0, key0.currency1));

        bytes memory data = plan.encode();
        router.executeActions(data);
        snapLastCall("Payments_swap_settleFromCaller_takeAllToMsgSender");
    }

    function test_gas_swap_settleWithBalance_takeAllToSpecifiedAddress() public {
        uint256 amountIn = 1 ether;
        IV4Router.ExactInputSingleParams memory params =
            IV4Router.ExactInputSingleParams(key0, true, uint128(amountIn), 0, 0, bytes(""));

        // seed the router with tokens
        key0.currency0.transfer(address(router), amountIn);

        plan = plan.add(Actions.SWAP_EXACT_IN_SINGLE, abi.encode(params));
        plan = plan.add(Actions.SETTLE, abi.encode(key0.currency0, ActionConstants.CONTRACT_BALANCE, false));
        plan = plan.add(Actions.TAKE, abi.encode(key0.currency1, address(this), ActionConstants.OPEN_DELTA));

        bytes memory data = plan.encode();
        router.executeActions(data);
        snapLastCall("Payments_swap_settleWithBalance_takeAllToSpecifiedAddress");
    }

    function test_gas_swap_settleWithBalance_takeAllToMsgSender() public {
        uint256 amountIn = 1 ether;
        IV4Router.ExactInputSingleParams memory params =
            IV4Router.ExactInputSingleParams(key0, true, uint128(amountIn), 0, 0, bytes(""));

        // seed the router with tokens
        key0.currency0.transfer(address(router), amountIn);

        plan = plan.add(Actions.SWAP_EXACT_IN_SINGLE, abi.encode(params));
        plan = plan.add(Actions.SETTLE, abi.encode(currency0, ActionConstants.CONTRACT_BALANCE, false));
        plan =
            plan.add(Actions.TAKE, abi.encode(key0.currency1, ActionConstants.MSG_SENDER, ActionConstants.OPEN_DELTA));

        bytes memory data = plan.encode();
        router.executeActions(data);
        snapLastCall("Payments_swap_settleWithBalance_takeAllToMsgSender");
    }
}
