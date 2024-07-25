// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {Test} from "forge-std/Test.sol";
import {GasSnapshot} from "forge-gas-snapshot/GasSnapshot.sol";
import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";

import {IV4Router} from "../src/interfaces/IV4Router.sol";
import {V4RouterImplementation} from "./shared/implementation/V4RouterImplementation.sol";
import {Plan, ActionsRouterPlanner} from "./shared/ActionsRouterPlanner.sol";
import {PathKey} from "../src/libraries/PathKey.sol";
import {Actions} from "../src/libraries/Actions.sol";

contract V4RouterTest is Test, Deployers, GasSnapshot {
    using CurrencyLibrary for Currency;
    using ActionsRouterPlanner for Plan;

    PoolModifyLiquidityTest positionManager;
    V4RouterImplementation router;

    // currency0 and currency1 are defined in Deployers.sol
    Currency currency2;
    Currency currency3;

    PoolKey key0;
    PoolKey key1;
    PoolKey key2;

    Currency[] tokenPath;

    Plan plan;

    function setUp() public {
        deployFreshManagerAndRouters();

        router = new V4RouterImplementation(manager);
        positionManager = new PoolModifyLiquidityTest(manager);

        MockERC20 token0 = new MockERC20("Test0", "0", 18);
        token0.mint(address(this), 2 ** 128);
        currency0 = Currency.wrap(address(token0));

        MockERC20 token1 = new MockERC20("Test1", "1", 18);
        token1.mint(address(this), 2 ** 128);
        currency1 = Currency.wrap(address(token1));

        MockERC20 token2 = new MockERC20("Test2", "2", 18);
        token2.mint(address(this), 2 ** 128);
        currency2 = Currency.wrap(address(token2));

        MockERC20 token3 = new MockERC20("Test3", "3", 18);
        token3.mint(address(this), 2 ** 128);
        currency3 = Currency.wrap(address(token3));

        key0 = createPoolKey(token0, token1, address(0));
        key1 = createPoolKey(token1, token2, address(0));
        key2 = createPoolKey(token2, token3, address(0));

        setupPool(key0);
        setupPool(key1);
        setupPool(key2);

        token0.approve(address(router), type(uint256).max);
        token1.approve(address(router), type(uint256).max);
        token2.approve(address(router), type(uint256).max);
        token3.approve(address(router), type(uint256).max);

        plan = ActionsRouterPlanner.init();
    }

    function testRouter_bytecodeSize() public {
        snapSize("RouterBytecode", address(router));
    }

    function testRouter_swapExactInputSingle_zeroForOne() public {
        uint256 amountIn = 1 ether;
        uint256 expectedAmountOut = 992054607780215625;

        IV4Router.ExactInputSingleParams memory params =
            IV4Router.ExactInputSingleParams(key0, true, uint128(amountIn), 0, 0, bytes(""));

        uint256 prevBalance0 = key0.currency0.balanceOf(address(this));
        uint256 prevBalance1 = key0.currency1.balanceOf(address(this));

        plan = plan.add(Actions.SWAP_EXACT_IN_SINGLE, abi.encode(params));
        _finalizePlan(key0.currency0, key0.currency1, address(this));
        bytes memory data = plan.encode();

        router.executeActions(data);
        snapLastCall("RouterExactInputSingle");

        uint256 newBalance0 = key0.currency0.balanceOf(address(this));
        uint256 newBalance1 = key0.currency1.balanceOf(address(this));

        assertEq(prevBalance0 - newBalance0, amountIn);
        assertEq(newBalance1 - prevBalance1, expectedAmountOut);
    }

    function testRouter_swapExactInputSingle_oneForZero() public {
        uint256 amountIn = 1 ether;
        uint256 expectedAmountOut = 992054607780215625;

        IV4Router.ExactInputSingleParams memory params =
            IV4Router.ExactInputSingleParams(key0, false, uint128(amountIn), 0, 0, bytes(""));

        uint256 prevBalance0 = key0.currency0.balanceOf(address(this));
        uint256 prevBalance1 = key0.currency1.balanceOf(address(this));

        plan = plan.add(Actions.SWAP_EXACT_IN_SINGLE, abi.encode(params));
        _finalizePlan(key0.currency1, key0.currency0, address(this));
        bytes memory data = plan.encode();

        router.executeActions(data);

        uint256 newBalance0 = key0.currency0.balanceOf(address(this));
        uint256 newBalance1 = key0.currency1.balanceOf(address(this));

        assertEq(prevBalance1 - newBalance1, amountIn);
        assertEq(newBalance0 - prevBalance0, expectedAmountOut);
    }

    function testRouter_swapExactIn_1Hop_zeroForOne() public {
        uint256 amountIn = 1 ether;
        uint256 expectedAmountOut = 992054607780215625;

        tokenPath.push(currency0);
        tokenPath.push(currency1);
        IV4Router.ExactInputParams memory params = _getExactInputParams(tokenPath, amountIn);

        uint256 prevBalance0 = currency0.balanceOfSelf();
        uint256 prevBalance1 = currency1.balanceOfSelf();

        plan = plan.add(Actions.SWAP_EXACT_IN, abi.encode(params));
        _finalizePlan(currency0, currency1, address(this));
        bytes memory data = plan.encode();

        router.executeActions(data);
        snapLastCall("RouterExactIn1Hop");

        uint256 newBalance0 = currency0.balanceOfSelf();
        uint256 newBalance1 = currency1.balanceOfSelf();

        assertEq(prevBalance0 - newBalance0, amountIn);
        assertEq(newBalance1 - prevBalance1, expectedAmountOut);
    }

    function testRouter_swapExactIn_1Hop_oneForZero() public {
        uint256 amountIn = 1 ether;
        uint256 expectedAmountOut = 992054607780215625;

        tokenPath.push(currency1);
        tokenPath.push(currency0);
        IV4Router.ExactInputParams memory params = _getExactInputParams(tokenPath, amountIn);
        uint256 prevBalance0 = currency0.balanceOfSelf();
        uint256 prevBalance1 = currency1.balanceOfSelf();

        plan = plan.add(Actions.SWAP_EXACT_IN, abi.encode(params));
        _finalizePlan(currency1, currency0, address(this));
        bytes memory data = plan.encode();

        router.executeActions(data);

        uint256 newBalance0 = currency0.balanceOfSelf();
        uint256 newBalance1 = currency1.balanceOfSelf();

        assertEq(prevBalance1 - newBalance1, amountIn);
        assertEq(newBalance0 - prevBalance0, expectedAmountOut);
    }

    function testRouter_swapExactIn_2Hops() public {
        uint256 amountIn = 1 ether;
        uint256 expectedAmountOut = 984211133872795298;

        tokenPath.push(currency0);
        tokenPath.push(currency1);
        tokenPath.push(currency2);
        IV4Router.ExactInputParams memory params = _getExactInputParams(tokenPath, amountIn);

        uint256 prevBalance0 = currency0.balanceOfSelf();
        uint256 prevBalance1 = currency1.balanceOfSelf();
        uint256 prevBalance2 = currency2.balanceOfSelf();

        plan = plan.add(Actions.SWAP_EXACT_IN, abi.encode(params));
        _finalizePlan(currency0, currency2, address(this));
        bytes memory data = plan.encode();

        router.executeActions(data);
        snapLastCall("RouterExactIn2Hops");

        uint256 newBalance0 = currency0.balanceOfSelf();
        uint256 newBalance1 = currency1.balanceOfSelf();
        uint256 newBalance2 = currency2.balanceOfSelf();

        assertEq(prevBalance0 - newBalance0, amountIn);
        assertEq(prevBalance1 - newBalance1, 0);
        assertEq(newBalance2 - prevBalance2, expectedAmountOut);
        assertEq(currency0.balanceOf(address(router)), 0);
        assertEq(currency1.balanceOf(address(router)), 0);
        assertEq(currency2.balanceOf(address(router)), 0);
    }

    function testRouter_swapExactIn_3Hops() public {
        uint256 amountIn = 1 ether;
        uint256 expectedAmountOut = 976467664490096191;

        tokenPath.push(currency0);
        tokenPath.push(currency1);
        tokenPath.push(currency2);
        tokenPath.push(currency3);
        IV4Router.ExactInputParams memory params = _getExactInputParams(tokenPath, amountIn);

        uint256 prevBalance0 = currency0.balanceOfSelf();
        uint256 prevBalance3 = currency3.balanceOfSelf();

        plan = plan.add(Actions.SWAP_EXACT_IN, abi.encode(params));
        _finalizePlan(currency0, currency3, address(this));
        bytes memory data = plan.encode();

        router.executeActions(data);
        snapLastCall("RouterExactIn3Hops");

        uint256 newBalance0 = currency0.balanceOfSelf();
        uint256 newBalance3 = currency3.balanceOfSelf();

        assertEq(prevBalance0 - newBalance0, amountIn);
        assertEq(newBalance3 - prevBalance3, expectedAmountOut);
        assertEq(currency0.balanceOf(address(router)), 0);
        assertEq(currency1.balanceOf(address(router)), 0);
        assertEq(currency2.balanceOf(address(router)), 0);
        assertEq(currency3.balanceOf(address(router)), 0);
    }

    function testRouter_swapExactOutputSingle_zeroForOne() public {
        uint256 amountOut = 1 ether;
        uint256 expectedAmountIn = 1008049273448486163;

        IV4Router.ExactOutputSingleParams memory params =
            IV4Router.ExactOutputSingleParams(key0, true, uint128(amountOut), 0, 0, bytes(""));

        uint256 prevBalance0 = key0.currency0.balanceOf(address(this));
        uint256 prevBalance1 = key0.currency1.balanceOf(address(this));

        plan = plan.add(Actions.SWAP_EXACT_OUT_SINGLE, abi.encode(params));
        _finalizePlan(key0.currency0, key0.currency1, address(this));
        bytes memory data = plan.encode();

        router.executeActions(data);
        snapLastCall("RouterExactOutputSingle");

        uint256 newBalance0 = key0.currency0.balanceOf(address(this));
        uint256 newBalance1 = key0.currency1.balanceOf(address(this));

        assertEq(prevBalance0 - newBalance0, expectedAmountIn);
        assertEq(newBalance1 - prevBalance1, amountOut);
    }

    function testRouter_swapExactOutputSingle_oneForZero() public {
        uint256 amountOut = 1 ether;
        uint256 expectedAmountIn = 1008049273448486163;

        IV4Router.ExactOutputSingleParams memory params =
            IV4Router.ExactOutputSingleParams(key0, false, uint128(amountOut), 0, 0, bytes(""));

        uint256 prevBalance0 = key0.currency0.balanceOf(address(this));
        uint256 prevBalance1 = key0.currency1.balanceOf(address(this));

        plan = plan.add(Actions.SWAP_EXACT_OUT_SINGLE, abi.encode(params));
        _finalizePlan(key0.currency1, key0.currency0, address(this));
        bytes memory data = plan.encode();

        router.executeActions(data);

        uint256 newBalance0 = key0.currency0.balanceOf(address(this));
        uint256 newBalance1 = key0.currency1.balanceOf(address(this));

        assertEq(prevBalance1 - newBalance1, expectedAmountIn);
        assertEq(newBalance0 - prevBalance0, amountOut);
    }

    function testRouter_swapExactOut_1Hop_zeroForOne() public {
        uint256 amountOut = 1 ether;
        uint256 expectedAmountIn = 1008049273448486163;

        tokenPath.push(currency0);
        tokenPath.push(currency1);
        IV4Router.ExactOutputParams memory params = _getExactOutputParams(tokenPath, amountOut);

        uint256 prevBalance0 = currency0.balanceOfSelf();
        uint256 prevBalance1 = currency1.balanceOfSelf();

        plan = plan.add(Actions.SWAP_EXACT_OUT, abi.encode(params));
        _finalizePlan(currency0, currency1, address(this));
        bytes memory data = plan.encode();

        router.executeActions(data);
        snapLastCall("RouterExactOut1Hop");

        uint256 newBalance0 = currency0.balanceOfSelf();
        uint256 newBalance1 = currency1.balanceOfSelf();

        assertEq(prevBalance0 - newBalance0, expectedAmountIn);
        assertEq(newBalance1 - prevBalance1, amountOut);
    }

    function testRouter_swapExactOut_1Hop_oneForZero() public {
        uint256 amountOut = 1 ether;
        uint256 expectedAmountIn = 1008049273448486163;

        tokenPath.push(currency1);
        tokenPath.push(currency0);
        IV4Router.ExactOutputParams memory params = _getExactOutputParams(tokenPath, amountOut);

        uint256 prevBalance0 = currency0.balanceOfSelf();
        uint256 prevBalance1 = currency1.balanceOfSelf();

        plan = plan.add(Actions.SWAP_EXACT_OUT, abi.encode(params));
        _finalizePlan(currency1, currency0, address(this));
        bytes memory data = plan.encode();

        router.executeActions(data);
        snapLastCall("RouterExactOut1Hop");

        uint256 newBalance0 = currency0.balanceOfSelf();
        uint256 newBalance1 = currency1.balanceOfSelf();

        assertEq(prevBalance1 - newBalance1, expectedAmountIn);
        assertEq(newBalance0 - prevBalance0, amountOut);
    }

    function testRouter_swapExactOut_2Hops() public {
        uint256 amountOut = 1 ether;
        uint256 expectedAmountIn = 1016204441757464409;

        tokenPath.push(currency0);
        tokenPath.push(currency1);
        tokenPath.push(currency2);
        IV4Router.ExactOutputParams memory params = _getExactOutputParams(tokenPath, amountOut);

        uint256 prevBalance0 = currency0.balanceOfSelf();
        uint256 prevBalance1 = currency1.balanceOfSelf();
        uint256 prevBalance2 = currency2.balanceOfSelf();

        plan = plan.add(Actions.SWAP_EXACT_OUT, abi.encode(params));
        _finalizePlan(currency0, currency2, address(this));
        bytes memory data = plan.encode();

        router.executeActions(data);
        snapLastCall("RouterExactOut2Hops");

        uint256 newBalance0 = currency0.balanceOfSelf();
        uint256 newBalance1 = currency1.balanceOfSelf();
        uint256 newBalance2 = currency2.balanceOfSelf();

        assertEq(prevBalance0 - newBalance0, expectedAmountIn);
        assertEq(prevBalance1 - newBalance1, 0);
        assertEq(newBalance2 - prevBalance2, amountOut);
        assertEq(currency0.balanceOf(address(router)), 0);
        assertEq(currency1.balanceOf(address(router)), 0);
        assertEq(currency2.balanceOf(address(router)), 0);
    }

    function testRouter_swapExactOut_3Hops() public {
        uint256 amountOut = 1 ether;
        uint256 expectedAmountIn = 1024467570922834110;

        tokenPath.push(currency0);
        tokenPath.push(currency1);
        tokenPath.push(currency2);
        tokenPath.push(currency3);
        IV4Router.ExactOutputParams memory params = _getExactOutputParams(tokenPath, amountOut);

        uint256 prevBalance0 = currency0.balanceOfSelf();
        uint256 prevBalance3 = currency3.balanceOfSelf();

        plan = plan.add(Actions.SWAP_EXACT_OUT, abi.encode(params));
        _finalizePlan(currency0, currency3, address(this));
        bytes memory data = plan.encode();

        router.executeActions(data);
        snapLastCall("RouterExactOut3Hops");

        uint256 newBalance0 = currency0.balanceOfSelf();
        uint256 newBalance3 = currency3.balanceOfSelf();

        assertEq(prevBalance0 - newBalance0, expectedAmountIn);
        assertEq(newBalance3 - prevBalance3, amountOut);
        assertEq(currency0.balanceOf(address(router)), 0);
        assertEq(currency1.balanceOf(address(router)), 0);
        assertEq(currency2.balanceOf(address(router)), 0);
        assertEq(currency3.balanceOf(address(router)), 0);
    }

    function createPoolKey(MockERC20 tokenA, MockERC20 tokenB, address hookAddr)
        internal
        pure
        returns (PoolKey memory)
    {
        if (address(tokenA) > address(tokenB)) (tokenA, tokenB) = (tokenB, tokenA);
        return PoolKey(Currency.wrap(address(tokenA)), Currency.wrap(address(tokenB)), 3000, 60, IHooks(hookAddr));
    }

    function setupPool(PoolKey memory poolKey) internal {
        manager.initialize(poolKey, SQRT_PRICE_1_1, ZERO_BYTES);
        MockERC20(Currency.unwrap(poolKey.currency0)).approve(address(positionManager), type(uint256).max);
        MockERC20(Currency.unwrap(poolKey.currency1)).approve(address(positionManager), type(uint256).max);
        positionManager.modifyLiquidity(
            poolKey, IPoolManager.ModifyLiquidityParams(-887220, 887220, 200 ether, 0), "0x"
        );
    }

    function _getExactInputParams(Currency[] memory _tokenPath, uint256 amountIn)
        internal
        pure
        returns (IV4Router.ExactInputParams memory params)
    {
        PathKey[] memory path = new PathKey[](_tokenPath.length - 1);
        for (uint256 i = 0; i < _tokenPath.length - 1; i++) {
            path[i] = PathKey(_tokenPath[i + 1], 3000, 60, IHooks(address(0)), bytes(""));
        }

        params.currencyIn = _tokenPath[0];
        params.path = path;
        params.amountIn = uint128(amountIn);
        params.amountOutMinimum = 0;
    }

    function _getExactOutputParams(Currency[] memory _tokenPath, uint256 amountOut)
        internal
        pure
        returns (IV4Router.ExactOutputParams memory params)
    {
        PathKey[] memory path = new PathKey[](_tokenPath.length - 1);
        for (uint256 i = _tokenPath.length - 1; i > 0; i--) {
            path[i - 1] = PathKey(_tokenPath[i - 1], 3000, 60, IHooks(address(0)), bytes(""));
        }

        params.currencyOut = _tokenPath[_tokenPath.length - 1];
        params.path = path;
        params.amountOut = uint128(amountOut);
        params.amountInMaximum = type(uint128).max;
    }

    function _finalizePlan(Currency inputCurrency, Currency outputCurrency, address recipient) internal {
        plan = plan.add(Actions.SETTLE, abi.encode(inputCurrency, router.ENTIRE_OPEN_DELTA()));
        plan = plan.add(Actions.TAKE, abi.encode(outputCurrency, recipient, router.ENTIRE_OPEN_DELTA()));
    }
}
