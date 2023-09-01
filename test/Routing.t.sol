// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import "forge-std/console.sol";

import {Test} from "forge-std/Test.sol";
import {Deployers} from "@uniswap/v4-core/test/foundry-tests/utils/Deployers.sol";
import {GasSnapshot} from "forge-gas-snapshot/GasSnapshot.sol";
import {MockERC20} from "@uniswap/v4-core/test/foundry-tests/utils/MockERC20.sol";
import {PoolModifyPositionTest} from "@uniswap/v4-core/contracts/test/PoolModifyPositionTest.sol";
import {PoolManager} from "@uniswap/v4-core/contracts/PoolManager.sol";
import {IPoolManager} from "@uniswap/v4-core/contracts/interfaces/IPoolManager.sol";
import {Routing} from "../contracts/Routing.sol";
import {RoutingImplementation} from "./shared/implementation/RoutingImplementation.sol";
import {PoolKey} from "@uniswap/v4-core/contracts/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/contracts/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/contracts/interfaces/IHooks.sol";

contract RoutingTest is Test, Deployers, GasSnapshot {
    using CurrencyLibrary for Currency;

    PoolManager manager;
    PoolModifyPositionTest positionManager;
    RoutingImplementation router;

    MockERC20 token0;
    MockERC20 token1;
    MockERC20 token2;
    MockERC20 token3;

    PoolKey key0;
    PoolKey key1;
    PoolKey key2;

    PoolKey[] path;

    function setUp() public {
        manager = new PoolManager(500000);
        router = new RoutingImplementation(manager);
        positionManager = new PoolModifyPositionTest(manager);

        token0 = new MockERC20("Test0", "0", 18, 2 ** 128);
        token1 = new MockERC20("Test1", "1", 18, 2 ** 128);
        token2 = new MockERC20("Test2", "2", 18, 2 ** 128);
        token3 = new MockERC20("Test3", "3", 18, 2 ** 128);

        key0 = createPoolKey(token0, token1);
        key1 = createPoolKey(token1, token2);
        key2 = createPoolKey(token2, token3);

        setupPool(key0);
        setupPool(key1);
        setupPool(key2);

        token0.approve(address(router), type(uint256).max);
        token1.approve(address(router), type(uint256).max);
        token2.approve(address(router), type(uint256).max);
        token3.approve(address(router), type(uint256).max);
    }

    function testRouter_bytecodeSize() public {
        snapSize("RouterBytecode", address(router));
    }

    function testRouter_swapExactIn_1Hop_zeroForOne() public {
        path.push(PoolKey(toCurrency(token0), toCurrency(token1), 3000, 60, IHooks(address(0))));
        PoolKey[] memory _pathCached = path;

        uint256 amountIn = 1 ether;
        uint256 expectedAmountOut = 992054607780215625;

        uint256 prevBalance0 = token0.balanceOf(address(this));
        uint256 prevBalance1 = token1.balanceOf(address(this));

        snapStart("RouterExactIn1Hop");
        router.swap(
            Routing.SwapType.ExactInput,
            abi.encode(Routing.ExactInputParams(_pathCached, address(this), uint128(amountIn), 0, 0))
        );
        snapEnd();

        uint256 newBalance0 = token0.balanceOf(address(this));
        uint256 newBalance1 = token1.balanceOf(address(this));

        assertEq(prevBalance0 - newBalance0, amountIn);
        assertEq(newBalance1 - prevBalance1, expectedAmountOut);
    }

    function testRouter_swapExactIn_1Hop_oneForZero() public {
        path.push(PoolKey(toCurrency(token1), toCurrency(token0), 3000, 60, IHooks(address(0))));

        uint256 amountIn = 1 ether;
        uint256 expectedAmountOut = 992054607780215625;

        uint256 prevBalance0 = token0.balanceOf(address(this));
        uint256 prevBalance1 = token1.balanceOf(address(this));

        router.swap(
            Routing.SwapType.ExactInput,
            abi.encode(Routing.ExactInputParams(path, address(this), uint128(amountIn), 0, 0))
        );

        uint256 newBalance0 = token0.balanceOf(address(this));
        uint256 newBalance1 = token1.balanceOf(address(this));

        assertEq(prevBalance1 - newBalance1, amountIn);
        assertEq(newBalance0 - prevBalance0, expectedAmountOut);
    }

    function testRouter_swapExactIn_2Hops() public {
        path.push(PoolKey(toCurrency(token0), toCurrency(token1), 3000, 60, IHooks(address(0))));
        path.push(PoolKey(toCurrency(token1), toCurrency(token2), 3000, 60, IHooks(address(0))));
        PoolKey[] memory _pathCached = path;

        uint256 amountIn = 1 ether;
        uint256 expectedAmountOut = 984211133872795298;

        uint256 prevBalance0 = token0.balanceOf(address(this));
        uint256 prevBalance1 = token1.balanceOf(address(this));
        uint256 prevBalance2 = token2.balanceOf(address(this));

        snapStart("RouterExactIn2Hops");
        router.swap(
            Routing.SwapType.ExactInput,
            abi.encode(Routing.ExactInputParams(_pathCached, address(this), uint128(amountIn), 0, 0))
        );
        snapEnd();

        uint256 newBalance0 = token0.balanceOf(address(this));
        uint256 newBalance1 = token1.balanceOf(address(this));
        uint256 newBalance2 = token2.balanceOf(address(this));

        assertEq(prevBalance0 - newBalance0, amountIn);
        assertEq(prevBalance1 - newBalance1, 0);
        assertEq(newBalance2 - prevBalance2, expectedAmountOut);
        assertEq(token0.balanceOf(address(router)), 0);
        assertEq(token1.balanceOf(address(router)), 0);
        assertEq(token2.balanceOf(address(router)), 0);
    }

    function testRouter_swapExactIn_3Hops() public {
        path.push(PoolKey(toCurrency(token0), toCurrency(token1), 3000, 60, IHooks(address(0))));
        path.push(PoolKey(toCurrency(token1), toCurrency(token2), 3000, 60, IHooks(address(0))));
        path.push(PoolKey(toCurrency(token2), toCurrency(token3), 3000, 60, IHooks(address(0))));
        PoolKey[] memory _pathCached = path;

        uint256 amountIn = 1 ether;
        uint256 expectedAmountOut = 976467664490096191;

        uint256 prevBalance0 = token0.balanceOf(address(this));
        uint256 prevBalance3 = token3.balanceOf(address(this));

        snapStart("RouterExactIn3Hops");
        router.swap(
            Routing.SwapType.ExactInput,
            abi.encode(Routing.ExactInputParams(_pathCached, address(this), uint128(amountIn), 0, 0))
        );
        snapEnd();

        uint256 newBalance0 = token0.balanceOf(address(this));
        uint256 newBalance3 = token3.balanceOf(address(this));

        assertEq(prevBalance0 - newBalance0, amountIn);
        assertEq(newBalance3 - prevBalance3, expectedAmountOut);
        assertEq(token0.balanceOf(address(router)), 0);
        assertEq(token1.balanceOf(address(router)), 0);
        assertEq(token2.balanceOf(address(router)), 0);
        assertEq(token3.balanceOf(address(router)), 0);
    }

    function createPoolKey(MockERC20 tokenA, MockERC20 tokenB) internal pure returns (PoolKey memory) {
        if (address(tokenA) > address(tokenB)) (tokenA, tokenB) = (tokenB, tokenA);
        return PoolKey(Currency.wrap(address(tokenA)), Currency.wrap(address(tokenB)), 3000, 60, IHooks(address(0)));
    }

    function setupPool(PoolKey memory poolKey) internal {
        manager.initialize(poolKey, SQRT_RATIO_1_1, ZERO_BYTES);
        MockERC20(Currency.unwrap(poolKey.currency0)).approve(address(positionManager), type(uint256).max);
        MockERC20(Currency.unwrap(poolKey.currency1)).approve(address(positionManager), type(uint256).max);
        positionManager.modifyPosition(poolKey, IPoolManager.ModifyPositionParams(-887220, 887220, 200 ether));
    }

    function toCurrency(MockERC20 token) internal pure returns (Currency) {
        return Currency.wrap(address(token));
    }
}
