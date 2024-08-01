// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PosmTestSetup} from "../shared/PosmTestSetup.sol";
import {MockSubscriber} from "../mocks/MockSubscriber.sol";
import {ISubscriber} from "../../src/interfaces/ISubscriber.sol";
import {PositionConfig} from "../../src/libraries/PositionConfig.sol";
import {IPositionManager} from "../../src/interfaces/IPositionManager.sol";
import {Plan, Planner} from "../shared/Planner.sol";
import {Actions} from "../../src/libraries/Actions.sol";

contract PositionManagerNotifierTest is Test, PosmTestSetup {
    using Planner for Plan;

    MockSubscriber sub;
    PositionConfig config;

    address alice = makeAddr("ALICE");
    address bob = makeAddr("BOB");

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();

        (key,) = initPool(currency0, currency1, IHooks(hook), 3000, SQRT_PRICE_1_1, ZERO_BYTES);

        // Requires currency0 and currency1 to be set in base Deployers contract.
        deployAndApprovePosm(manager);

        sub = new MockSubscriber(lpm);
        config = PositionConfig({poolKey: key, tickLower: -300, tickUpper: 300});

        // TODO: Test NATIVE poolKey
    }

    function test_subscribe_revertsWithEmptyPositionConfig() public {
        uint256 tokenId = lpm.nextTokenId();
        vm.expectRevert("NOT_MINTED");
        lpm.subscribe(tokenId, config, address(sub));
    }

    function test_subscribe_revertsWhenNotApproved() public {
        uint256 tokenId = lpm.nextTokenId();
        mint(config, 100e18, alice, ZERO_BYTES);

        // this contract is not approved to operate on alice's liq

        vm.expectRevert(abi.encodeWithSelector(IPositionManager.NotApproved.selector, address(this)));
        lpm.subscribe(tokenId, config, address(sub));
    }

    function test_subscribe_reverts_withIncorrectConfig() public {
        uint256 tokenId = lpm.nextTokenId();
        mint(config, 100e18, alice, ZERO_BYTES);

        // approve this contract to operate on alices liq
        vm.startPrank(alice);
        lpm.approve(address(this), tokenId);
        vm.stopPrank();

        PositionConfig memory incorrectConfig = PositionConfig({poolKey: key, tickLower: -300, tickUpper: 301});

        vm.expectRevert(abi.encodeWithSelector(IPositionManager.IncorrectPositionConfigForTokenId.selector, tokenId));
        lpm.subscribe(tokenId, incorrectConfig, address(sub));
    }

    function test_subscribe_succeeds() public {
        uint256 tokenId = lpm.nextTokenId();
        mint(config, 100e18, alice, ZERO_BYTES);

        // approve this contract to operate on alices liq
        vm.startPrank(alice);
        lpm.approve(address(this), tokenId);
        vm.stopPrank();

        lpm.subscribe(tokenId, config, address(sub));

        assertEq(_getSubscribed(lpm.positionConfigs(tokenId)), true);
        assertEq(address(lpm.subscriber(tokenId)), address(sub));
        assertEq(sub.notifySubscribeCount(), 1);
    }

    function test_notifyModifyLiquidity_succeeds() public {
        uint256 tokenId = lpm.nextTokenId();
        mint(config, 100e18, alice, ZERO_BYTES);

        // approve this contract to operate on alices liq
        vm.startPrank(alice);
        lpm.approve(address(this), tokenId);
        vm.stopPrank();

        lpm.subscribe(tokenId, config, address(sub));

        Plan memory plan = Planner.init();
        for (uint256 i = 0; i < 10; i++) {
            plan.add(Actions.INCREASE_LIQUIDITY, abi.encode(tokenId, config, 10e18, ZERO_BYTES));
        }

        bytes memory calls = plan.finalizeModifyLiquidity(config.poolKey);
        lpm.modifyLiquidities(calls, _deadline);

        assertEq(sub.notifySubscribeCount(), 1);
        assertEq(sub.notifyModifyLiquidityCount(), 10);
    }

    function test_notifyTransfer_withTransferFrom_succeeds() public {
        uint256 tokenId = lpm.nextTokenId();
        mint(config, 100e18, alice, ZERO_BYTES);

        // approve this contract to operate on alices liq
        vm.startPrank(alice);
        lpm.approve(address(this), tokenId);
        vm.stopPrank();

        lpm.subscribe(tokenId, config, address(sub));

        lpm.transferFrom(alice, bob, tokenId);

        assertEq(sub.notifyTransferCount(), 1);
    }

    function _getSubscribed(bytes32 _config) internal pure returns (bool subscribed) {
        assembly {
            subscribed := shr(255, _config)
        }
    }
}
