// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PositionInfo, PositionInfoLibrary, PoolId} from "../../src/libraries/PositionInfoLibrary.sol";

contract PositionInfoLibraryTest is Test {
    function setUp() public {}

    function test_fuzz_initialize(PoolKey memory poolKey, int24 tickLower, int24 tickUpper) public pure {
        PositionInfo info = PositionInfoLibrary.initialize(poolKey, tickLower, tickUpper);

        assertEq(info.poolId(), bytes25(PoolId.unwrap(poolKey.toId())));
        assertEq(info.tickLower(), tickLower);
        assertEq(info.tickUpper(), tickUpper);
        assertEq(info.hasSubscriber(), false);
    }

    function test_fuzz_initialize_setSubscribed(PoolKey memory poolKey, int24 tickLower, int24 tickUpper) public pure {
        PositionInfo info = PositionInfoLibrary.initialize(poolKey, tickLower, tickUpper);
        assertEq(info.hasSubscriber(), false);
        info = info.setSubscribe();
        assertEq(info.hasSubscriber(), true);
        assertEq(info.tickLower(), tickLower);
        assertEq(info.tickUpper(), tickUpper);
        assertEq(info.poolId(), bytes25(PoolId.unwrap(poolKey.toId())));
    }

    function test_fuzz_initialize_setUnsubscribed(PoolKey memory poolKey, int24 tickLower, int24 tickUpper)
        public
        pure
    {
        PositionInfo info = PositionInfoLibrary.initialize(poolKey, tickLower, tickUpper);
        assertEq(info.hasSubscriber(), false);
        info = info.setSubscribe();
        assertEq(info.hasSubscriber(), true);
        assertEq(info.tickLower(), tickLower);
        assertEq(info.tickUpper(), tickUpper);
        assertEq(info.poolId(), bytes25(PoolId.unwrap(poolKey.toId())));

        info = info.setUnsubscribe();
        assertEq(info.hasSubscriber(), false);
        assertEq(info.tickLower(), tickLower);
        assertEq(info.tickUpper(), tickUpper);
        assertEq(info.poolId(), bytes25(PoolId.unwrap(poolKey.toId())));
    }

    function test_fuzz_setSubscribe(PoolKey memory poolKey, int24 tickLower, int24 tickUpper) public pure {
        PositionInfo info = PositionInfoLibrary.initialize(poolKey, tickLower, tickUpper);
        assertEq(info.hasSubscriber(), false);
        info = info.setSubscribe();
        assertEq(info.hasSubscriber(), true);

        // Calling set subscribe again does nothing.
        info = info.setSubscribe();
        assertEq(info.hasSubscriber(), true);
    }

    function test_fuzz_setUnsubscribe(PoolKey memory poolKey, int24 tickLower, int24 tickUpper) public pure {
        PositionInfo info = PositionInfoLibrary.initialize(poolKey, tickLower, tickUpper);
        assertEq(info.hasSubscriber(), false);
        info = info.setSubscribe();
        assertEq(info.hasSubscriber(), true);
        info = info.setUnsubscribe();
        assertEq(info.hasSubscriber(), false);

        // Calling set unsubscribe again does nothing.
        info = info.setUnsubscribe();
        assertEq(info.hasSubscriber(), false);
    }
}
