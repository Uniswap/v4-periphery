// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {V4RouterImplementation} from "../shared/implementation/V4RouterImplementation.sol";
import {Plan, ActionsRouterPlanner} from "../shared/ActionsRouterPlanner.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PathKey} from "../../src/libraries/PathKey.sol";
import {Actions} from "../../src/libraries/Actions.sol";

import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {PositionManager} from "../../src/PositionManager.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {LiquidityOperations} from "./LiquidityOperations.sol";
import {IV4Router} from "../../src/interfaces/IV4Router.sol";

/// @notice A shared test contract that wraps the v4-core deployers contract and exposes basic helpers for swapping with the router.
contract RoutingTestHelpers is Test, Deployers {
    using ActionsRouterPlanner for Plan;

    PoolModifyLiquidityTest positionManager;
    V4RouterImplementation router;

    // nativeKey is already defined in Deployers.sol
    PoolKey key0;
    PoolKey key1;
    PoolKey key2;

    // currency0 and currency1 are defined in Deployers.sol
    Currency currency2;
    Currency currency3;

    Currency[] tokenPath;
    Plan plan;

    function setupRouterCurrenciesAndPoolsWithLiquidity() public {
        deployFreshManager();

        router = new V4RouterImplementation(manager);
        positionManager = new PoolModifyLiquidityTest(manager);

        MockERC20[] memory tokens = deployTokensMintAndApprove(4);

        currency0 = Currency.wrap(address(tokens[0]));
        currency1 = Currency.wrap(address(tokens[1]));
        currency2 = Currency.wrap(address(tokens[2]));
        currency3 = Currency.wrap(address(tokens[3]));

        nativeKey = createNativePoolWithLiquidity(currency0, address(0));
        key0 = createPoolWithLiquidity(currency0, currency1, address(0));
        key1 = createPoolWithLiquidity(currency1, currency2, address(0));
        key2 = createPoolWithLiquidity(currency2, currency3, address(0));
    }

    function deployTokensMintAndApprove(uint8 count) internal returns (MockERC20[] memory) {
        MockERC20[] memory tokens = deployTokens(count, 2 ** 128);
        for (uint256 i = 0; i < count; i++) {
            tokens[i].approve(address(router), type(uint256).max);
        }
        return tokens;
    }

    function createPoolWithLiquidity(Currency currencyA, Currency currencyB, address hookAddr)
        internal
        returns (PoolKey memory _key)
    {
        if (Currency.unwrap(currencyA) > Currency.unwrap(currencyB)) (currencyA, currencyB) = (currencyB, currencyA);
        _key = PoolKey(currencyA, currencyB, 3000, 60, IHooks(hookAddr));

        manager.initialize(_key, SQRT_PRICE_1_1, ZERO_BYTES);
        MockERC20(Currency.unwrap(currencyA)).approve(address(positionManager), type(uint256).max);
        MockERC20(Currency.unwrap(currencyB)).approve(address(positionManager), type(uint256).max);
        positionManager.modifyLiquidity(_key, IPoolManager.ModifyLiquidityParams(-887220, 887220, 200 ether, 0), "0x");
    }

    function createNativePoolWithLiquidity(Currency currency, address hookAddr)
        internal
        returns (PoolKey memory _key)
    {
        _key = PoolKey(CurrencyLibrary.NATIVE, currency, 3000, 60, IHooks(hookAddr));

        manager.initialize(_key, SQRT_PRICE_1_1, ZERO_BYTES);
        MockERC20(Currency.unwrap(currency)).approve(address(positionManager), type(uint256).max);
        positionManager.modifyLiquidity{value: 200 ether}(
            _key, IPoolManager.ModifyLiquidityParams(-887220, 887220, 200 ether, 0), "0x"
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

    function _finalizeExecuteAndCheckSwap(
        Currency inputCurrency,
        Currency outputCurrency,
        uint256 amountIn,
        uint256 amountOut
    ) internal {
        _finalizeExecuteAndCheckSwap(inputCurrency, outputCurrency, amountIn, amountOut, false);
    }

    function _finalizeExecuteAndCheckSwap(
        Currency inputCurrency,
        Currency outputCurrency,
        uint256 amountIn,
        uint256 amountOut,
        bool ethInputExactOutput
    ) internal {
        uint256 prevBalanceIn = inputCurrency.balanceOfSelf();
        uint256 prevBalanceOut = outputCurrency.balanceOfSelf();

        bytes memory data = plan.finalizeSwap(inputCurrency, outputCurrency, address(this));

        uint256 value = (inputCurrency.isNative()) ? amountIn : 0;

        if (ethInputExactOutput) {
            // send too much ETH to mimic slippage
            // then make sure the router can sweep back excess input
            value += 0.1 ether;
            router.executeActionsAndSweepExcessETH{value: value}(data);
        } else {
            // otherwise just execute as normal
            router.executeActions{value: value}(data);
        }

        uint256 newBalanceIn = inputCurrency.balanceOfSelf();
        uint256 newBalanceOut = outputCurrency.balanceOfSelf();

        assertEq(prevBalanceIn - newBalanceIn, amountIn);
        assertEq(newBalanceOut - prevBalanceOut, amountOut);
        assertEq(inputCurrency.balanceOf(address(router)), 0);
        assertEq(outputCurrency.balanceOf(address(router)), 0);
    }
}
