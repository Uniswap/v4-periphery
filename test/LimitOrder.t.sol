// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {Test} from "forge-std/Test.sol";
import {GetSender} from "./shared/GetSender.sol";
import {Hooks} from "@uniswap/v4-core/contracts/libraries/Hooks.sol";
import {LimitOrder, Epoch, EpochLibrary} from "../contracts/hooks/examples/LimitOrder.sol";
import {LimitOrderImplementation} from "./shared/implementation/LimitOrderImplementation.sol";
import {PoolManager} from "@uniswap/v4-core/contracts/PoolManager.sol";
import {IPoolManager} from "@uniswap/v4-core/contracts/interfaces/IPoolManager.sol";
import {Deployers} from "@uniswap/v4-core/test/foundry-tests/utils/Deployers.sol";
import {TestERC20} from "@uniswap/v4-core/contracts/test/TestERC20.sol";
import {CurrencyLibrary, Currency} from "@uniswap/v4-core/contracts/libraries/CurrencyLibrary.sol";
import {PoolId} from "@uniswap/v4-core/contracts/libraries/PoolId.sol";
import {PoolSwapTest} from "@uniswap/v4-core/contracts/test/PoolSwapTest.sol";
import {TickMath} from "@uniswap/v4-core/contracts/libraries/TickMath.sol";

contract TestLimitOrder is Test, Deployers {
    uint160 constant SQRT_RATIO_10_1 = 250541448375047931186413801569;

    TestERC20 token0;
    TestERC20 token1;
    PoolManager manager;
    LimitOrder limitOrder = LimitOrder(address(uint160(Hooks.AFTER_INITIALIZE_FLAG | Hooks.AFTER_SWAP_FLAG)));
    IPoolManager.PoolKey key;
    bytes32 id;

    PoolSwapTest swapRouter;

    function setUp() public {
        token0 = new TestERC20(2**128);
        token1 = new TestERC20(2**128);
        manager = new PoolManager(500000);

        vm.record();
        LimitOrderImplementation impl = new LimitOrderImplementation(manager, limitOrder);
        (, bytes32[] memory writes) = vm.accesses(address(impl));
        vm.etch(address(limitOrder), address(impl).code);
        // for each storage key that was written during the hook implementation, copy the value over
        unchecked {
            for (uint256 i = 0; i < writes.length; i++) {
                bytes32 slot = writes[i];
                vm.store(address(limitOrder), slot, vm.load(address(impl), slot));
            }
        }

        key = IPoolManager.PoolKey(Currency.wrap(address(token0)), Currency.wrap(address(token1)), 3000, 60, limitOrder);
        id = PoolId.toId(key);
        manager.initialize(key, SQRT_RATIO_1_1);

        swapRouter = new PoolSwapTest(manager);

        token0.approve(address(limitOrder), type(uint256).max);
        token1.approve(address(limitOrder), type(uint256).max);
        token0.approve(address(swapRouter), type(uint256).max);
        token1.approve(address(swapRouter), type(uint256).max);
    }

    function testGetTickLowerLast() public {
        assertEq(limitOrder.getTickLowerLast(id), 0);
    }

    function testGetTickLowerLastWithDifferentPrice() public {
        IPoolManager.PoolKey memory differentKey =
            IPoolManager.PoolKey(Currency.wrap(address(token0)), Currency.wrap(address(token1)), 3000, 61, limitOrder);
        manager.initialize(differentKey, SQRT_RATIO_10_1);
        assertEq(limitOrder.getTickLowerLast(PoolId.toId(differentKey)), 22997);
    }

    function testEpochNext() public {
        assertTrue(EpochLibrary.equals(limitOrder.epochNext(), Epoch.wrap(1)));
    }

    function testZeroLiquidityRevert() public {
        vm.expectRevert(LimitOrder.ZeroLiquidity.selector);
        limitOrder.place(key, 0, true, 0);
    }

    function testZeroForOneRightBoundaryOfCurrentRange() public {
        int24 tickLower = 60;
        bool zeroForOne = true;
        uint128 liquidity = 1000000;
        limitOrder.place(key, tickLower, zeroForOne, liquidity);
        assertTrue(EpochLibrary.equals(limitOrder.getEpoch(key, tickLower, zeroForOne), Epoch.wrap(1)));
        assertEq(manager.getLiquidity(id, address(limitOrder), tickLower, tickLower + 60), liquidity);
    }

    function testZeroForOneLeftBoundaryOfCurrentRange() public {
        int24 tickLower = 0;
        bool zeroForOne = true;
        uint128 liquidity = 1000000;
        limitOrder.place(key, tickLower, zeroForOne, liquidity);
        assertTrue(EpochLibrary.equals(limitOrder.getEpoch(key, tickLower, zeroForOne), Epoch.wrap(1)));
        assertEq(manager.getLiquidity(id, address(limitOrder), tickLower, tickLower + 60), liquidity);
    }

    function testZeroForOneCrossedRangeRevert() public {
        vm.expectRevert(LimitOrder.CrossedRange.selector);
        limitOrder.place(key, -60, true, 1000000);
    }

    function testZeroForOneInRangeRevert() public {
        // swapping is free, there's no liquidity in the pool, so we only need to specify 1 wei
        swapRouter.swap(
            key, IPoolManager.SwapParams(false, 1, SQRT_RATIO_1_1 + 1), PoolSwapTest.TestSettings(true, true)
        );
        vm.expectRevert(LimitOrder.InRange.selector);
        limitOrder.place(key, 0, true, 1000000);
    }

    function testNotZeroForOneLeftBoundaryOfCurrentRange() public {
        int24 tickLower = -60;
        bool zeroForOne = false;
        uint128 liquidity = 1000000;
        limitOrder.place(key, tickLower, zeroForOne, liquidity);
        assertTrue(EpochLibrary.equals(limitOrder.getEpoch(key, tickLower, zeroForOne), Epoch.wrap(1)));
        assertEq(manager.getLiquidity(id, address(limitOrder), tickLower, tickLower + 60), liquidity);
    }

    function testNotZeroForOneCrossedRangeRevert() public {
        vm.expectRevert(LimitOrder.CrossedRange.selector);
        limitOrder.place(key, 0, false, 1000000);
    }

    function testNotZeroForOneInRangeRevert() public {
        // swapping is free, there's no liquidity in the pool, so we only need to specify 1 wei
        swapRouter.swap(
            key, IPoolManager.SwapParams(true, 1, SQRT_RATIO_1_1 - 1), PoolSwapTest.TestSettings(true, true)
        );
        vm.expectRevert(LimitOrder.InRange.selector);
        limitOrder.place(key, -60, false, 1000000);
    }

    function testMultipleLPs() public {
        int24 tickLower = 60;
        bool zeroForOne = true;
        uint128 liquidity = 1000000;
        limitOrder.place(key, tickLower, zeroForOne, liquidity);
        address other = 0x1111111111111111111111111111111111111111;
        token0.transfer(other, 1e18);
        token1.transfer(other, 1e18);
        vm.startPrank(other);
        token0.approve(address(limitOrder), type(uint256).max);
        token1.approve(address(limitOrder), type(uint256).max);
        limitOrder.place(key, tickLower, zeroForOne, liquidity);
        vm.stopPrank();
        assertTrue(EpochLibrary.equals(limitOrder.getEpoch(key, tickLower, zeroForOne), Epoch.wrap(1)));
        assertEq(manager.getLiquidity(id, address(limitOrder), tickLower, tickLower + 60), liquidity * 2);

        (
            bool filled,
            Currency currency0,
            Currency currency1,
            uint256 token0Total,
            uint256 token1Total,
            uint128 liquidityTotal
        ) = limitOrder.epochInfos(Epoch.wrap(1));
        assertFalse(filled);
        assertTrue(CurrencyLibrary.equals(currency0, Currency.wrap(address(token0))));
        assertTrue(CurrencyLibrary.equals(currency1, Currency.wrap(address(token1))));
        assertEq(token0Total, 0);
        assertEq(token1Total, 0);
        assertEq(liquidityTotal, liquidity * 2);
        assertEq(limitOrder.getEpochLiquidity(Epoch.wrap(1), new GetSender().sender()), liquidity);
        assertEq(limitOrder.getEpochLiquidity(Epoch.wrap(1), other), liquidity);
    }

    event Transfer(address indexed from, address indexed to, uint256 value);

    function testKill() public {
        int24 tickLower = 0;
        bool zeroForOne = true;
        uint128 liquidity = 1000000;
        limitOrder.place(key, tickLower, zeroForOne, liquidity);
        vm.expectEmit(true, true, true, true, address(token0));
        emit Transfer(address(manager), new GetSender().sender(), 2995);
        limitOrder.kill(key, tickLower, zeroForOne, new GetSender().sender());
    }

    function testSwapAcrossRange() public {
        int24 tickLower = 0;
        bool zeroForOne = true;
        uint128 liquidity = 1000000;
        limitOrder.place(key, tickLower, zeroForOne, liquidity);

        swapRouter.swap(
            key,
            IPoolManager.SwapParams(false, 1e18, TickMath.getSqrtRatioAtTick(60)),
            PoolSwapTest.TestSettings(true, true)
        );

        assertEq(limitOrder.getTickLowerLast(id), 60);
        (, int24 tick,) = manager.getSlot0(id);
        assertEq(tick, 60);

        (bool filled,,, uint256 token0Total, uint256 token1Total,) = limitOrder.epochInfos(Epoch.wrap(1));

        assertTrue(filled);
        assertEq(token0Total, 0);
        assertEq(token1Total, 2996 + 17); // 3013, 2 wei of dust
        assertEq(manager.getLiquidity(id, address(limitOrder), tickLower, tickLower + 60), 0);

        vm.expectEmit(true, true, true, true, address(token1));
        emit Transfer(address(manager), new GetSender().sender(), 2996 + 17);
        limitOrder.withdraw(Epoch.wrap(1), new GetSender().sender());

        (,,, token0Total, token1Total,) = limitOrder.epochInfos(Epoch.wrap(1));

        assertEq(token0Total, 0);
        assertEq(token1Total, 0);
    }
}
