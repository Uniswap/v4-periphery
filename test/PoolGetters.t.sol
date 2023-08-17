// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {Test} from "forge-std/Test.sol";
import {PoolManager} from "@uniswap/v4-core/contracts/PoolManager.sol";
import {IPoolManager} from "@uniswap/v4-core/contracts/interfaces/IPoolManager.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/contracts/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/contracts/types/PoolKey.sol";
import {GasSnapshot} from "forge-gas-snapshot/GasSnapshot.sol";
import {Deployers} from "@uniswap/v4-core/test/foundry-tests/utils/Deployers.sol";
import {PoolModifyPositionTest} from "@uniswap/v4-core/contracts/test/PoolModifyPositionTest.sol";
import {TickMath} from "@uniswap/v4-core/contracts/libraries/TickMath.sol";
import {TestERC20} from "@uniswap/v4-core/contracts/test/TestERC20.sol";
import {CurrencyLibrary, Currency} from "@uniswap/v4-core/contracts/types/Currency.sol";

import {PoolGetters} from "../contracts/libraries/PoolGetters.sol";

contract TestGeomeanOracle is Test, Deployers {
    using PoolIdLibrary for PoolKey;
    using PoolGetters for IPoolManager;
    using CurrencyLibrary for Currency;

    PoolKey key;
    PoolId id;

    PoolManager manager;

    TestERC20 token0;
    TestERC20 token1;

    PoolModifyPositionTest modifyPositionRouter;

    function setUp() public {
        token0 = new TestERC20(2**128);
        token1 = new TestERC20(2**128);
        manager = new PoolManager(500000);

        key =
            PoolKey(Currency.wrap(address(token0)), Currency.wrap(address(token1)), 0, 60, address(0));
        id = key.toId();

        manager.initialize(key, SQRT_RATIO_1_1);

        modifyPositionRouter = new PoolModifyPositionTest(IPoolManager(address(manager)));

        modifyPositionRouter.modifyPosition(key, IPoolManager.ModifyPositionParams(-60, 60, 10 ether));
        modifyPositionRouter.modifyPosition(key, IPoolManager.ModifyPositionParams(-120, 120, 10 ether));
        modifyPositionRouter.modifyPosition(
            key, IPoolManager.ModifyPositionParams(TickMath.minUsableTick(60), TickMath.maxUsableTick(60), 10 ether)
        );

    }

    function testGetPoolSqrtPrice() public {
        uint160 sqrtPriceX96;

        snapStart("PoolGettersGetPoolSqrtPrice");
        sqrtPriceX96 = manager.getPoolSqrtPrice(id);
        snapEnd();

        (uint160 sqrtPriceX96Slot0,,,,,) = manager.getSlot0(id);
        assertEq(sqrtPriceX96, sqrtPriceX96Slot0);
    }

    
}
