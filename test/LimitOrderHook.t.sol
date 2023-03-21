// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {Test} from "forge-std/Test.sol";

contract TestLimitOrderHook is Test {
    function setUp() public {
        MockHooks impl = new MockHooks();
        vm.etch(ALL_HOOKS_ADDRESS, address(impl).code);
        mockHooks = MockHooks(ALL_HOOKS_ADDRESS);
        (manager, key,) = Deployers.createFreshPool(mockHooks, 3000, SQRT_RATIO_1_1);
        modifyPositionRouter = new PoolModifyPositionTest(IPoolManager(address(manager)));
        swapRouter = new PoolSwapTest(IPoolManager(address(manager)));
        donateRouter = new PoolDonateTest(IPoolManager(address(manager)));
    }
}
