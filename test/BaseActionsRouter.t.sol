//SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {MockBaseActionsRouter} from "./mocks/MockBaseActionsRouter.sol";
import {Planner, Plan} from "./shared/Planner.sol";
import {Actions} from "../src/libraries/Actions.sol";
import {ActionConstants} from "../src/libraries/ActionConstants.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Test} from "forge-std/Test.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {GasSnapshot} from "forge-gas-snapshot/GasSnapshot.sol";

contract BaseActionsRouterTest is Test, Deployers, GasSnapshot {
    using Planner for Plan;

    MockBaseActionsRouter router;

    function setUp() public {
        deployFreshManager();
        router = new MockBaseActionsRouter(manager);
    }

    function test_swap_suceeds() public {
        Plan memory plan = Planner.init();
        for (uint256 i = 0; i < 10; i++) {
            plan.add(Actions.SWAP_EXACT_IN, "");
        }

        bytes memory data = plan.encode();

        assertEq(router.swapCount(), 0);

        router.executeActions(data);
        snapLastCall("BaseActionsRouter_mock10commands");
        assertEq(router.swapCount(), 10);
    }

    function test_increaseLiquidity_suceeds() public {
        Plan memory plan = Planner.init();
        for (uint256 i = 0; i < 10; i++) {
            plan.add(Actions.INCREASE_LIQUIDITY, "");
        }

        assertEq(router.increaseLiqCount(), 0);

        bytes memory data = plan.encode();
        router.executeActions(data);
        assertEq(router.increaseLiqCount(), 10);
    }

    function test_decreaseLiquidity_suceeds() public {
        Plan memory plan = Planner.init();
        for (uint256 i = 0; i < 10; i++) {
            plan.add(Actions.DECREASE_LIQUIDITY, "");
        }

        assertEq(router.decreaseLiqCount(), 0);

        bytes memory data = plan.encode();
        router.executeActions(data);
        assertEq(router.decreaseLiqCount(), 10);
    }

    function test_donate_suceeds() public {
        Plan memory plan = Planner.init();
        for (uint256 i = 0; i < 10; i++) {
            plan.add(Actions.DONATE, "");
        }

        assertEq(router.donateCount(), 0);

        bytes memory data = plan.encode();
        router.executeActions(data);
        assertEq(router.donateCount(), 10);
    }

    function test_clear_suceeds() public {
        Plan memory plan = Planner.init();
        for (uint256 i = 0; i < 10; i++) {
            plan.add(Actions.CLEAR_OR_TAKE, "");
        }

        assertEq(router.clearCount(), 0);

        bytes memory data = plan.encode();
        router.executeActions(data);
        assertEq(router.clearCount(), 10);
    }

    function test_settle_suceeds() public {
        Plan memory plan = Planner.init();
        for (uint256 i = 0; i < 10; i++) {
            plan.add(Actions.SETTLE, "");
        }

        assertEq(router.settleCount(), 0);

        bytes memory data = plan.encode();
        router.executeActions(data);
        assertEq(router.settleCount(), 10);
    }

    function test_take_suceeds() public {
        Plan memory plan = Planner.init();
        for (uint256 i = 0; i < 10; i++) {
            plan.add(Actions.TAKE, "");
        }

        assertEq(router.takeCount(), 0);

        bytes memory data = plan.encode();
        router.executeActions(data);
        assertEq(router.takeCount(), 10);
    }

    function test_mint_suceeds() public {
        Plan memory plan = Planner.init();
        for (uint256 i = 0; i < 10; i++) {
            plan.add(Actions.MINT_6909, "");
        }

        assertEq(router.mintCount(), 0);

        bytes memory data = plan.encode();
        router.executeActions(data);
        assertEq(router.mintCount(), 10);
    }

    function test_burn_suceeds() public {
        Plan memory plan = Planner.init();
        for (uint256 i = 0; i < 10; i++) {
            plan.add(Actions.BURN_6909, "");
        }

        assertEq(router.burnCount(), 0);

        bytes memory data = plan.encode();
        router.executeActions(data);
        assertEq(router.burnCount(), 10);
    }

    function test_fuzz_mapRecipient(address recipient) public view {
        address mappedRecipient = router.mapRecipient(recipient);
        if (recipient == ActionConstants.MSG_SENDER) {
            assertEq(mappedRecipient, address(0xdeadbeef));
        } else if (recipient == ActionConstants.ADDRESS_THIS) {
            assertEq(mappedRecipient, address(router));
        } else {
            assertEq(mappedRecipient, recipient);
        }
    }
}
