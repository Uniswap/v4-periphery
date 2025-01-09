// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {IERC721} from "forge-std/interfaces/IERC721.sol";

import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";

import {IPositionManager} from "../../src/interfaces/IPositionManager.sol";
import {INotifier} from "../../src/interfaces/INotifier.sol";
import {ISubscriber} from "../../src/interfaces/ISubscriber.sol";
import {ReentrancyLock} from "../../src/base/ReentrancyLock.sol";
import {Actions} from "../../src/libraries/Actions.sol";
import {PositionConfig} from "../shared/PositionConfig.sol";

import {LiquidityFuzzers} from "../shared/fuzz/LiquidityFuzzers.sol";
import {PosmTestSetup} from "../shared/PosmTestSetup.sol";
import {MockReentrantSubscriber} from "../mocks/MockReentrantSubscriber.sol";

contract PositionManagerModifyLiquiditiesTest is Test, PosmTestSetup, LiquidityFuzzers {
    using StateLibrary for IPoolManager;

    address alice;
    uint256 alicePK;
    address bob;

    MockReentrantSubscriber sub;

    PositionConfig config;

    function setUp() public {
        (alice, alicePK) = makeAddrAndKey("ALICE");
        (bob,) = makeAddrAndKey("BOB");

        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();

        // Requires currency0 and currency1 to be set in base Deployers contract.
        deployAndApprovePosm(manager);

        seedBalance(alice);
        approvePosmFor(alice);

        // must deploy after posm
        // Deploys a hook which can accesses IPositionManager.modifyLiquiditiesWithoutUnlock
        deployPosmHookModifyLiquidities();
        seedBalance(address(hookModifyLiquidities));

        (key,) = initPool(currency0, currency1, IHooks(hookModifyLiquidities), 3000, SQRT_PRICE_1_1);
        wethKey = initPoolUnsorted(Currency.wrap(address(_WETH9)), currency1, IHooks(address(0)), 3000, SQRT_PRICE_1_1);

        sub = new MockReentrantSubscriber(lpm);

        config = PositionConfig({poolKey: key, tickLower: -60, tickUpper: 60});
    }

    /// @dev calling modifyLiquiditiesWithoutUnlock without a lock will revert
    function test_modifyLiquiditiesWithoutUnlock_revert() public {
        bytes memory calls = getMintEncoded(config, 10e18, address(this), ZERO_BYTES);
        (bytes memory actions, bytes[] memory params) = abi.decode(calls, (bytes, bytes[]));
        vm.expectRevert(IPoolManager.ManagerLocked.selector);
        lpm.modifyLiquiditiesWithoutUnlock(actions, params);
    }

    /// @dev subscribers cannot re-enter posm on-subscribe since PM is not unlocked
    function test_fuzz_subscriber_subscribe_reenter_revert(uint256 seed) public {
        uint256 tokenId = lpm.nextTokenId();
        mint(config, 100e18, address(this), ZERO_BYTES);

        // approve the subscriber to modify liquidity
        IERC721(address(lpm)).approve(address(sub), tokenId);

        // randomly sample a single action
        bytes memory calls = getFuzzySingleEncoded(seed, tokenId, config, 10e18, ZERO_BYTES);

        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(sub),
                ISubscriber.notifySubscribe.selector,
                abi.encodeWithSelector(IPoolManager.ManagerLocked.selector),
                abi.encodeWithSelector(INotifier.SubscriptionReverted.selector)
            )
        );
        lpm.subscribe(tokenId, address(sub), calls);
    }

    /// @dev subscribers cannot re-enter posm on-unsubscribe since PM is not unlocked
    function test_fuzz_subscriber_unsubscribe_reenter(uint256 seed) public {
        uint256 tokenId = lpm.nextTokenId();
        mint(config, 100e18, address(this), ZERO_BYTES);

        // approve the subscriber to modify liquidity
        IERC721(address(lpm)).approve(address(sub), tokenId);
        lpm.subscribe(tokenId, address(sub), ZERO_BYTES);

        // randomly sample a single action
        bytes memory calls = getFuzzySingleEncoded(seed, tokenId, config, 10e18, ZERO_BYTES);
        (bytes memory actions, bytes[] memory params) = abi.decode(calls, (bytes, bytes[]));
        sub.setActionsAndParams(actions, params);
        lpm.unsubscribe(tokenId);

        // subscriber did not modify liquidity
        assertEq(IERC721(address(lpm)).ownerOf(tokenId), address(this)); // owner still owns the position
        assertEq(lpm.nextTokenId(), tokenId + 1); // no new token minted
        assertEq(lpm.getPositionLiquidity(tokenId), 100e18); // liquidity unchanged

        // token was unsubscribed
        assertEq(address(lpm.subscriber(tokenId)), address(0));
        assertEq(lpm.positionInfo(tokenId).hasSubscriber(), false);
    }

    /// @dev subscribers cannot re-enter posm on-notifyModifyLiquidity because of no reentrancy guards
    function test_fuzz_subscriber_notifyModifyLiquidity_reenter_revert(uint256 seed0, uint256 seed1) public {
        uint256 tokenId = lpm.nextTokenId();
        mint(config, 100e18, address(this), ZERO_BYTES);

        // approve the subscriber to modify liquidity
        IERC721(address(lpm)).approve(address(sub), tokenId);

        lpm.subscribe(tokenId, address(sub), ZERO_BYTES);

        // randomly sample a single action
        bytes memory action = getFuzzySingleEncoded(seed0, tokenId, config, 10e18, ZERO_BYTES);
        (bytes memory actions, bytes[] memory params) = abi.decode(action, (bytes, bytes[]));
        sub.setActionsAndParams(actions, params);

        // modify the token (dont mint)
        bytes memory calls;
        if (seed1 % 3 == 0) {
            calls = getIncreaseEncoded(tokenId, config, 10e18, ZERO_BYTES);
            vm.expectRevert(
                abi.encodeWithSelector(
                    CustomRevert.WrappedError.selector,
                    address(sub),
                    ISubscriber.notifyModifyLiquidity.selector,
                    abi.encodeWithSelector(ReentrancyLock.ContractLocked.selector),
                    abi.encodeWithSelector(INotifier.ModifyLiquidityNotificationReverted.selector)
                )
            );
        } else if (seed1 % 3 == 1) {
            calls = getDecreaseEncoded(tokenId, config, 10e18, ZERO_BYTES);
            vm.expectRevert(
                abi.encodeWithSelector(
                    CustomRevert.WrappedError.selector,
                    address(sub),
                    ISubscriber.notifyModifyLiquidity.selector,
                    abi.encodeWithSelector(ReentrancyLock.ContractLocked.selector),
                    abi.encodeWithSelector(INotifier.ModifyLiquidityNotificationReverted.selector)
                )
            );
        } else {
            calls = getBurnEncoded(tokenId, config, ZERO_BYTES);
            vm.expectRevert(
                abi.encodeWithSelector(
                    CustomRevert.WrappedError.selector,
                    address(sub),
                    ISubscriber.notifyBurn.selector,
                    abi.encodeWithSelector(ReentrancyLock.ContractLocked.selector),
                    abi.encodeWithSelector(INotifier.BurnNotificationReverted.selector)
                )
            );
        }

        // should revert because subscriber is re-entering modifyLiquiditiesWithoutUnlock
        lpm.modifyLiquidities(calls, _deadline);
    }

    /// @dev subscribers cannot re-enter posm on-notifyUnsubscribe because position manager is not unlocked
    function test_fuzz_subscriber_transfer_reenter_unmodified(uint256 seed) public {
        uint256 tokenId = lpm.nextTokenId();
        mint(config, 100e18, address(this), ZERO_BYTES);

        uint256 liquidityBefore = lpm.getPositionLiquidity(tokenId);

        // approve the subscriber to modify liquidity
        IERC721(address(lpm)).approve(address(sub), tokenId);

        lpm.subscribe(tokenId, address(sub), ZERO_BYTES);

        // randomly sample a single action
        bytes memory action = getFuzzySingleEncoded(seed, tokenId, config, 10e18, ZERO_BYTES);
        (bytes memory actions, bytes[] memory params) = abi.decode(action, (bytes, bytes[]));
        sub.setActionsAndParams(actions, params);

        // on transfer, the subscriber is called `notifyUnsubscribe` which will attempt to modify liquidity
        // this call is reverted, but the unsubscribe is still successful
        IERC721(address(lpm)).transferFrom(address(this), address(sub), tokenId);

        // verify the position's liquidity is not modified
        assertEq(lpm.getPositionLiquidity(tokenId), liquidityBefore);
    }

    /// @dev hook cannot re-enter modifyLiquiditiesWithoutUnlock in beforeAddLiquidity
    function test_fuzz_hook_beforeAddLiquidity_reenter_revert(uint256 seed) public {
        uint256 initialLiquidity = 100e18;
        uint256 tokenId = lpm.nextTokenId();
        mint(config, initialLiquidity, address(this), ZERO_BYTES);

        uint256 liquidityToChange = 10e18;

        // a random action be provided as hookData, so beforeAddLiquidity will attempt to modifyLiquidity
        bytes memory hookCall = getFuzzySingleEncoded(seed, tokenId, config, liquidityToChange, ZERO_BYTES);
        bytes memory calls = getIncreaseEncoded(tokenId, config, liquidityToChange, hookCall);

        // should revert because hook is re-entering modifyLiquiditiesWithoutUnlock
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hookModifyLiquidities),
                IHooks.beforeAddLiquidity.selector,
                abi.encodeWithSelector(ReentrancyLock.ContractLocked.selector),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        lpm.modifyLiquidities(calls, _deadline);
    }

    /// @dev hook cannot re-enter modifyLiquiditiesWithoutUnlock in beforeRemoveLiquidity
    function test_fuzz_hook_beforeRemoveLiquidity_reenter_revert(uint256 seed) public {
        uint256 initialLiquidity = 100e18;
        uint256 tokenId = lpm.nextTokenId();
        mint(config, initialLiquidity, address(this), ZERO_BYTES);

        uint256 liquidityToChange = 10e18;

        // a random action be provided as hookData, so beforeAddLiquidity will attempt to modifyLiquidity
        bytes memory hookCall = getFuzzySingleEncoded(seed, tokenId, config, liquidityToChange, ZERO_BYTES);
        bytes memory calls = getDecreaseEncoded(tokenId, config, liquidityToChange, hookCall);

        // should revert because hook is re-entering modifyLiquiditiesWithoutUnlock
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hookModifyLiquidities),
                IHooks.beforeRemoveLiquidity.selector,
                abi.encodeWithSelector(ReentrancyLock.ContractLocked.selector),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        lpm.modifyLiquidities(calls, _deadline);
    }

    /// @dev hook cannot re-enter modifyLiquiditiesWithoutUnlock in afterAddLiquidity
    function test_fuzz_hook_afterAddLiquidity_reenter_revert(uint256 seed) public {
        uint256 initialLiquidity = 100e18;
        uint256 tokenId = lpm.nextTokenId();
        mint(config, initialLiquidity, address(this), ZERO_BYTES);

        uint256 liquidityToChange = 10e18;

        // a random action be provided as hookData, so afterAddLiquidity will attempt to modifyLiquidity
        bytes memory hookCall = getFuzzySingleEncoded(seed, tokenId, config, liquidityToChange, ZERO_BYTES);
        bytes memory calls = getIncreaseEncoded(tokenId, config, liquidityToChange, hookCall);

        // should revert because hook is re-entering modifyLiquiditiesWithoutUnlock
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hookModifyLiquidities),
                IHooks.beforeAddLiquidity.selector,
                abi.encodeWithSelector(ReentrancyLock.ContractLocked.selector),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        lpm.modifyLiquidities(calls, _deadline);
    }

    /// @dev hook cannot re-enter modifyLiquiditiesWithoutUnlock in afterRemoveLiquidity
    function test_fuzz_hook_afterRemoveLiquidity_reenter_revert(uint256 seed) public {
        uint256 initialLiquidity = 100e18;
        uint256 tokenId = lpm.nextTokenId();
        mint(config, initialLiquidity, address(this), ZERO_BYTES);

        uint256 liquidityToChange = 10e18;

        // a random action be provided as hookData, so afterAddLiquidity will attempt to modifyLiquidity
        bytes memory hookCall = getFuzzySingleEncoded(seed, tokenId, config, liquidityToChange, ZERO_BYTES);
        bytes memory calls = getDecreaseEncoded(tokenId, config, liquidityToChange, hookCall);

        // should revert because hook is re-entering modifyLiquiditiesWithoutUnlock
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hookModifyLiquidities),
                IHooks.beforeRemoveLiquidity.selector,
                abi.encodeWithSelector(ReentrancyLock.ContractLocked.selector),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        lpm.modifyLiquidities(calls, _deadline);
    }
}
