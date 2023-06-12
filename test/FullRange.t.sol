// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {Test} from "forge-std/Test.sol";
import {Hooks} from "@uniswap/v4-core/contracts/libraries/Hooks.sol";
import {FullRange} from "../contracts/hooks/FullRange.sol";
import {FullRangeImplementation} from "./shared/implementation/FullRangeImplementation.sol";
import {PoolManager} from "@uniswap/v4-core/contracts/PoolManager.sol";
import {IPoolManager} from "@uniswap/v4-core/contracts/interfaces/IPoolManager.sol";
import {Deployers} from "@uniswap/v4-core/test/foundry-tests/utils/Deployers.sol";
import {TestERC20} from "@uniswap/v4-core/contracts/test/TestERC20.sol";
import {CurrencyLibrary, Currency} from "@uniswap/v4-core/contracts/libraries/CurrencyLibrary.sol";
import {PoolId} from "@uniswap/v4-core/contracts/libraries/PoolId.sol";
import {PoolModifyPositionTest} from "@uniswap/v4-core/contracts/test/PoolModifyPositionTest.sol";
import {TickMath} from "@uniswap/v4-core/contracts/libraries/TickMath.sol";
import {Oracle} from "../contracts/libraries/Oracle.sol";

contract TestFullRange is Test, Deployers {
    int24 constant TICK_SPACING = 60;
    uint160 constant SQRT_RATIO_2_1 = 112045541949572279837463876454;

    TestERC20 token0;
    TestERC20 token1;
    PoolManager manager;
    FullRangeImplementation fullRange = FullRangeImplementation(
        address(
            uint160(Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_MODIFY_POSITION_FLAG)
        )
    );
    IPoolManager.PoolKey key;
    bytes32 id;

    PoolModifyPositionTest modifyPositionRouter;

    function setUp() public {
        token0 = new TestERC20(2**128);
        token1 = new TestERC20(2**128);
        manager = new PoolManager(500000);

        vm.record();
        FullRangeImplementation impl = new FullRangeImplementation(manager, fullRange);
        (, bytes32[] memory writes) = vm.accesses(address(impl));
        vm.etch(address(fullRange), address(impl).code);
        // for each storage key that was written during the hook implementation, copy the value over
        unchecked {
            for (uint256 i = 0; i < writes.length; i++) {
                bytes32 slot = writes[i];
                vm.store(address(fullRange), slot, vm.load(address(impl), slot));
            }
        }
        key = IPoolManager.PoolKey(
            Currency.wrap(address(token0)), Currency.wrap(address(token1)), 0, TICK_SPACING, fullRange
        );
        id = PoolId.toId(key);

        // modifyPositionRouter = new PoolModifyPositionTest(manager);

        // token0.approve(address(geomeanOracle), type(uint256).max);
        // token1.approve(address(geomeanOracle), type(uint256).max);
        // token0.approve(address(modifyPositionRouter), type(uint256).max);
        // token1.approve(address(modifyPositionRouter), type(uint256).max);
    }

    function testBeforeInitializeAllowsPoolCreation() public {
        manager.initialize(key, SQRT_RATIO_1_1);
    }

    // function testBeforeInitializeRevertsIfWrongSpacing() public {

    // }

    // function testBeforeModifyPositionSucceeds() public {

    // }

    // function testBeforeModifyPositionFailsIfNoPool() public {

    // }
}
