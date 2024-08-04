// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Position} from "@uniswap/v4-core/src/libraries/Position.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {GasSnapshot} from "forge-gas-snapshot/GasSnapshot.sol";
import {PosmTestSetup} from "../shared/PosmTestSetup.sol";
import {MockSubscriber} from "../mocks/MockSubscriber.sol";
import {ISubscriber} from "../../src/interfaces/ISubscriber.sol";
import {PositionConfig} from "../../src/libraries/PositionConfig.sol";
import {IPositionManager} from "../../src/interfaces/IPositionManager.sol";
import {Plan, Planner} from "../shared/Planner.sol";
import {Actions} from "../../src/libraries/Actions.sol";
import {MockReturnDataSubscriber} from "../mocks/MockBadSubscribers.sol";

contract PositionManagerNotifierTest is Test, PosmTestSetup, GasSnapshot {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using Planner for Plan;

    MockSubscriber sub;
    MockReturnDataSubscriber badSubscriber;
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
        badSubscriber = new MockReturnDataSubscriber(lpm);
        config = PositionConfig({poolKey: key, tickLower: -300, tickUpper: 300});

        // TODO: Test NATIVE poolKey
    }

    function test_subscribe_revertsWithEmptyPositionConfig() public {
        uint256 tokenId = lpm.nextTokenId();
        vm.expectRevert("NOT_MINTED");
        lpm.subscribe(tokenId, config, address(sub), ZERO_BYTES);
    }

    function test_subscribe_revertsWhenNotApproved() public {
        uint256 tokenId = lpm.nextTokenId();
        mint(config, 100e18, alice, ZERO_BYTES);

        // this contract is not approved to operate on alice's liq

        vm.expectRevert(abi.encodeWithSelector(IPositionManager.NotApproved.selector, address(this)));
        lpm.subscribe(tokenId, config, address(sub), ZERO_BYTES);
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
        lpm.subscribe(tokenId, incorrectConfig, address(sub), ZERO_BYTES);
    }

    function test_subscribe_succeeds() public {
        uint256 tokenId = lpm.nextTokenId();
        mint(config, 100e18, alice, ZERO_BYTES);

        // approve this contract to operate on alices liq
        vm.startPrank(alice);
        lpm.approve(address(this), tokenId);
        vm.stopPrank();

        lpm.subscribe(tokenId, config, address(sub), ZERO_BYTES);

        assertEq(lpm.hasSubscriber(tokenId), true);
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

        lpm.subscribe(tokenId, config, address(sub), ZERO_BYTES);

        assertEq(lpm.hasSubscriber(tokenId), true);
        assertEq(address(lpm.subscriber(tokenId)), address(sub));

        Plan memory plan = Planner.init();
        for (uint256 i = 0; i < 10; i++) {
            plan.add(
                Actions.INCREASE_LIQUIDITY,
                abi.encode(tokenId, config, 10e18, MAX_SLIPPAGE_INCREASE, MAX_SLIPPAGE_INCREASE, ZERO_BYTES)
            );
        }

        bytes memory calls = plan.finalizeModifyLiquidityWithSettlePair(config.poolKey);
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

        lpm.subscribe(tokenId, config, address(sub), ZERO_BYTES);

        assertEq(lpm.hasSubscriber(tokenId), true);
        assertEq(address(lpm.subscriber(tokenId)), address(sub));

        lpm.transferFrom(alice, bob, tokenId);

        assertEq(sub.notifyTransferCount(), 1);
    }

    function test_notifyTransfer_withSafeTransferFrom_succeeds() public {
        uint256 tokenId = lpm.nextTokenId();
        mint(config, 100e18, alice, ZERO_BYTES);

        // approve this contract to operate on alices liq
        vm.startPrank(alice);
        lpm.approve(address(this), tokenId);
        vm.stopPrank();

        lpm.subscribe(tokenId, config, address(sub), ZERO_BYTES);

        assertEq(lpm.hasSubscriber(tokenId), true);
        assertEq(address(lpm.subscriber(tokenId)), address(sub));

        lpm.safeTransferFrom(alice, bob, tokenId);

        assertEq(sub.notifyTransferCount(), 1);
    }

    function test_notifyTransfer_withSafeTransferFromData_succeeds() public {
        uint256 tokenId = lpm.nextTokenId();
        mint(config, 100e18, alice, ZERO_BYTES);

        // approve this contract to operate on alices liq
        vm.startPrank(alice);
        lpm.approve(address(this), tokenId);
        vm.stopPrank();

        lpm.subscribe(tokenId, config, address(sub), ZERO_BYTES);

        assertEq(lpm.hasSubscriber(tokenId), true);
        assertEq(address(lpm.subscriber(tokenId)), address(sub));

        lpm.safeTransferFrom(alice, bob, tokenId, "");

        assertEq(sub.notifyTransferCount(), 1);
    }

    function test_unsubscribe_succeeds() public {
        uint256 tokenId = lpm.nextTokenId();
        mint(config, 100e18, alice, ZERO_BYTES);

        // approve this contract to operate on alices liq
        vm.startPrank(alice);
        lpm.approve(address(this), tokenId);
        vm.stopPrank();

        lpm.subscribe(tokenId, config, address(sub), ZERO_BYTES);

        lpm.unsubscribe(tokenId, config, ZERO_BYTES);

        assertEq(sub.notifyUnsubscribeCount(), 1);
        assertEq(lpm.hasSubscriber(tokenId), false);
        assertEq(address(lpm.subscriber(tokenId)), address(0));
    }

    function test_unsubscribe_isSuccessfulWithBadSubscriber() public {
        uint256 tokenId = lpm.nextTokenId();
        mint(config, 100e18, alice, ZERO_BYTES);

        // approve this contract to operate on alices liq
        vm.startPrank(alice);
        lpm.approve(address(this), tokenId);
        vm.stopPrank();

        lpm.subscribe(tokenId, config, address(badSubscriber), ZERO_BYTES);

        MockReturnDataSubscriber(badSubscriber).setReturnDataSize(0x600000);
        lpm.unsubscribe(tokenId, config, ZERO_BYTES);

        // the subscriber contract call failed bc it used too much gas
        assertEq(MockReturnDataSubscriber(badSubscriber).notifyUnsubscribeCount(), 0);
        assertEq(lpm.hasSubscriber(tokenId), false);
        assertEq(address(lpm.subscriber(tokenId)), address(0));
    }

    function test_multicall_mint_subscribe() public {
        uint256 tokenId = lpm.nextTokenId();

        Plan memory plan = Planner.init();
        plan.add(
            Actions.MINT_POSITION,
            abi.encode(config, 100e18, MAX_SLIPPAGE_INCREASE, MAX_SLIPPAGE_INCREASE, address(this), ZERO_BYTES)
        );
        bytes memory actions = plan.finalizeModifyLiquidityWithSettlePair(config.poolKey);

        bytes[] memory calls = new bytes[](2);

        calls[0] = abi.encodeWithSelector(lpm.modifyLiquidities.selector, actions, _deadline);
        calls[1] = abi.encodeWithSelector(lpm.subscribe.selector, tokenId, config, sub, ZERO_BYTES);

        lpm.multicall(calls);

        uint256 liquidity = lpm.getPositionLiquidity(tokenId, config);

        assertEq(liquidity, 100e18);
        assertEq(sub.notifySubscribeCount(), 1);

        assertEq(lpm.hasSubscriber(tokenId), true);
        assertEq(address(lpm.subscriber(tokenId)), address(sub));
    }

    function test_multicall_mint_subscribe_increase() public {
        uint256 tokenId = lpm.nextTokenId();

        // Encode mint.
        Plan memory plan = Planner.init();
        plan.add(
            Actions.MINT_POSITION,
            abi.encode(config, 100e18, MAX_SLIPPAGE_INCREASE, MAX_SLIPPAGE_INCREASE, address(this), ZERO_BYTES)
        );
        bytes memory actions = plan.finalizeModifyLiquidityWithSettlePair(config.poolKey);

        // Encode increase separately.
        plan = Planner.init();
        plan.add(
            Actions.INCREASE_LIQUIDITY,
            abi.encode(tokenId, config, 10e18, MAX_SLIPPAGE_INCREASE, MAX_SLIPPAGE_INCREASE, ZERO_BYTES)
        );
        bytes memory actions2 = plan.finalizeModifyLiquidityWithSettlePair(config.poolKey);

        bytes[] memory calls = new bytes[](3);

        calls[0] = abi.encodeWithSelector(lpm.modifyLiquidities.selector, actions, _deadline);
        calls[1] = abi.encodeWithSelector(lpm.subscribe.selector, tokenId, config, sub, ZERO_BYTES);
        calls[2] = abi.encodeWithSelector(lpm.modifyLiquidities.selector, actions2, _deadline);

        lpm.multicall(calls);

        uint256 liquidity = lpm.getPositionLiquidity(tokenId, config);

        assertEq(liquidity, 110e18);
        assertEq(sub.notifySubscribeCount(), 1);
        assertEq(sub.notifyModifyLiquidityCount(), 1);
        assertEq(lpm.hasSubscriber(tokenId), true);
        assertEq(address(lpm.subscriber(tokenId)), address(sub));
    }

    function test_unsubscribe_revertsWhenNotSubscribed() public {
        uint256 tokenId = lpm.nextTokenId();
        mint(config, 100e18, alice, ZERO_BYTES);

        // approve this contract to operate on alices liq
        vm.startPrank(alice);
        lpm.approve(address(this), tokenId);
        vm.stopPrank();

        vm.expectRevert();
        lpm.unsubscribe(tokenId, config, ZERO_BYTES);
    }

    function test_subscribe_withData() public {
        uint256 tokenId = lpm.nextTokenId();
        mint(config, 100e18, alice, ZERO_BYTES);

        bytes memory subData = abi.encode(address(this));

        // approve this contract to operate on alices liq
        vm.startPrank(alice);
        lpm.approve(address(this), tokenId);
        vm.stopPrank();

        lpm.subscribe(tokenId, config, address(sub), subData);

        assertEq(lpm.hasSubscriber(tokenId), true);
        assertEq(address(lpm.subscriber(tokenId)), address(sub));
        assertEq(sub.notifySubscribeCount(), 1);
        assertEq(abi.decode(sub.subscribeData(), (address)), address(this));
    }

    function test_unsubscribe_withData() public {
        uint256 tokenId = lpm.nextTokenId();
        mint(config, 100e18, alice, ZERO_BYTES);

        bytes memory subData = abi.encode(address(this));

        // approve this contract to operate on alices liq
        vm.startPrank(alice);
        lpm.approve(address(this), tokenId);
        vm.stopPrank();

        lpm.subscribe(tokenId, config, address(sub), ZERO_BYTES);

        lpm.unsubscribe(tokenId, config, subData);

        assertEq(sub.notifyUnsubscribeCount(), 1);
        assertEq(lpm.hasSubscriber(tokenId), false);
        assertEq(address(lpm.subscriber(tokenId)), address(0));
        assertEq(abi.decode(sub.unsubscribeData(), (address)), address(this));
    }
}
