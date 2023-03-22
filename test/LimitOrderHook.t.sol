// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {Test, console2} from "forge-std/Test.sol";
import {Hooks} from "@uniswap/core-next/contracts/libraries/Hooks.sol";
import {LimitOrderHook, Epoch, EpochLibrary} from "../contracts/hooks/LimitOrderHook.sol";
import {PoolManager} from "@uniswap/core-next/contracts/PoolManager.sol";
import {IPoolManager} from "@uniswap/core-next/contracts/interfaces/IPoolManager.sol";
import {Deployers} from "@uniswap/core-next/test/foundry-tests/utils/Deployers.sol";
import {TestERC20} from "@uniswap/core-next/contracts/test/TestERC20.sol";
import {Currency} from "@uniswap/core-next/contracts/libraries/CurrencyLibrary.sol";
import {PoolId} from "@uniswap/core-next/contracts/libraries/PoolId.sol";

contract LimitOrderHookImplementation is LimitOrderHook {
    constructor(IPoolManager _poolManager, LimitOrderHook addressToEtch) LimitOrderHook(_poolManager) {
        Hooks.validateHookAddress(addressToEtch, getOwnHooksCalls());
    }

    // make this a no-op in testing
    function validateHookAddress(LimitOrderHook _this) internal override {}
}

contract TestLimitOrderHook is Test, Deployers {
    uint160 constant SQRT_RATIO_1_1 = 79228162514264337593543950336;
    uint160 constant SQRT_RATIO_10_1 = 250541448375047931186413801569;

    TestERC20 token0;
    TestERC20 token1;
    PoolManager manager;
    LimitOrderHook limitOrderHook =
        LimitOrderHook(address(uint160(Hooks.AFTER_INITIALIZE_FLAG | Hooks.AFTER_SWAP_FLAG)));
    IPoolManager.PoolKey key;
    bytes32 id;

    // PoolModifyPositionTest modifyPositionRouter;
    // PoolSwapTest swapRouter;
    // PoolDonateTest donateRouter;

    function setUp() public {
        token0 = new TestERC20(2**128);
        token1 = new TestERC20(2**128);
        manager = new PoolManager(500000);

        vm.record();
        LimitOrderHookImplementation impl = new LimitOrderHookImplementation(manager, limitOrderHook);
        vm.etch(address(limitOrderHook), address(impl).code);
        (, bytes32[] memory writes) = vm.accesses(address(impl));
        // for each storage key that was written during the hook implementation, copy the value over
        unchecked {
            for (uint256 i = 0; i < writes.length; i++) {
                bytes32 slot = writes[i];
                vm.store(address(limitOrderHook), slot, vm.load(address(impl), slot));
            }
        }

        key = IPoolManager.PoolKey(
            Currency.wrap(address(token0)), Currency.wrap(address(token1)), 3000, 60, limitOrderHook
        );
        id = PoolId.toId(key);
        manager.initialize(key, SQRT_RATIO_1_1);

        // modifyPositionRouter = new PoolModifyPositionTest(IPoolManager(address(manager)));
        // swapRouter = new PoolSwapTest(IPoolManager(address(manager)));
        // donateRouter = new PoolDonateTest(IPoolManager(address(manager)));
    }

    function testGetTickLowerLast() public {
        assertEq(limitOrderHook.getTickLowerLast(id), 0);
    }

    function testGetTickLowerLastWithDifferentPrice() public {
        IPoolManager.PoolKey memory differentKey = IPoolManager.PoolKey(
            Currency.wrap(address(token0)), Currency.wrap(address(token1)), 3000, 61, limitOrderHook
        );
        manager.initialize(differentKey, SQRT_RATIO_10_1);
        assertEq(limitOrderHook.getTickLowerLast(PoolId.toId(differentKey)), 22997);
    }

    function testEpochNext() public {
        assertTrue(EpochLibrary.equals(limitOrderHook.epochNext(), Epoch.wrap(1)));
    }
}
