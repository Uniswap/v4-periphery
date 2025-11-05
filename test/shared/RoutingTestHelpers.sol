// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {MockV4Router} from "../mocks/MockV4Router.sol";
import {Plan, Planner} from "../shared/Planner.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PathKey} from "../../src/libraries/PathKey.sol";
import {Actions} from "../../src/libraries/Actions.sol";

import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {LiquidityOperations} from "./LiquidityOperations.sol";
import {IV4Router} from "../../src/interfaces/IV4Router.sol";
import {ActionConstants} from "../../src/libraries/ActionConstants.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

/// @notice A shared test contract that wraps the v4-core deployers contract and exposes basic helpers for swapping with the router.
contract RoutingTestHelpers is Test, Deployers {
    PoolModifyLiquidityTest positionManager;
    MockV4Router router;

    uint256 MAX_SETTLE_AMOUNT = type(uint256).max;
    uint256 MIN_TAKE_AMOUNT = 0;

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

        router = new MockV4Router(manager);
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
        if (Currency.unwrap(currencyA) > Currency.unwrap(currencyB)) {
            (currencyA, currencyB) = (currencyB, currencyA);
        }
        _key = PoolKey(currencyA, currencyB, 3000, 60, IHooks(hookAddr));

        manager.initialize(_key, SQRT_PRICE_1_1);
        MockERC20(Currency.unwrap(currencyA)).approve(address(positionManager), type(uint256).max);
        MockERC20(Currency.unwrap(currencyB)).approve(address(positionManager), type(uint256).max);
        positionManager.modifyLiquidity(_key, ModifyLiquidityParams(-887220, 887220, 200 ether, 0), "0x");
    }

    function createNativePoolWithLiquidity(Currency currency, address hookAddr) internal returns (PoolKey memory _key) {
        _key = PoolKey(CurrencyLibrary.ADDRESS_ZERO, currency, 3000, 60, IHooks(hookAddr));

        manager.initialize(_key, SQRT_PRICE_1_1);
        MockERC20(Currency.unwrap(currency)).approve(address(positionManager), type(uint256).max);
        positionManager.modifyLiquidity{value: 200 ether}(
            _key, ModifyLiquidityParams(-887220, 887220, 200 ether, 0), "0x"
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
        params.maxHopSlippage = new uint256[](0);
        params.amountIn = uint128(amountIn);
        params.amountOutMinimum = 0;
    }

    function _getExactInputParams(Currency[] memory _tokenPath, uint256[] memory maxHopSlippage, uint256 amountIn)
        internal
        pure
        returns (IV4Router.ExactInputParams memory params)
    {
        params = _getExactInputParams(_tokenPath, amountIn);
        params.maxHopSlippage = maxHopSlippage;
        return params;
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
        params.maxHopSlippage = new uint256[](0);
        params.amountOut = uint128(amountOut);
        params.amountInMaximum = type(uint128).max;
    }

    function _getExactOutputParams(Currency[] memory _tokenPath, uint256[] memory maxHopSlippage, uint256 amountOut)
        internal
        pure
        returns (IV4Router.ExactOutputParams memory params)
    {
        params = _getExactOutputParams(_tokenPath, amountOut);
        params.maxHopSlippage = maxHopSlippage;
        return params;
    }

    function _finalizeAndExecuteSwap(
        Currency inputCurrency,
        Currency outputCurrency,
        uint256 amountIn,
        address takeRecipient
    )
        internal
        returns (
            uint256 inputBalanceBefore,
            uint256 outputBalanceBefore,
            uint256 inputBalanceAfter,
            uint256 outputBalanceAfter
        )
    {
        inputBalanceBefore = inputCurrency.balanceOfSelf();
        outputBalanceBefore = outputCurrency.balanceOfSelf();

        bytes memory data = plan.finalizeSwap(inputCurrency, outputCurrency, takeRecipient);

        uint256 value = (inputCurrency.isAddressZero()) ? amountIn : 0;

        // otherwise just execute as normal
        router.executeActions{value: value}(data);

        inputBalanceAfter = inputCurrency.balanceOfSelf();
        outputBalanceAfter = outputCurrency.balanceOfSelf();
    }

    function _finalizeAndExecuteSwap(Currency inputCurrency, Currency outputCurrency, uint256 amountIn)
        internal
        returns (
            uint256 inputBalanceBefore,
            uint256 outputBalanceBefore,
            uint256 inputBalanceAfter,
            uint256 outputBalanceAfter
        )
    {
        return _finalizeAndExecuteSwap(inputCurrency, outputCurrency, amountIn, ActionConstants.MSG_SENDER);
    }

    function _finalizeAndExecuteNativeInputExactOutputSwap(
        Currency inputCurrency,
        Currency outputCurrency,
        uint256 expectedAmountIn
    )
        internal
        returns (
            uint256 inputBalanceBefore,
            uint256 outputBalanceBefore,
            uint256 inputBalanceAfter,
            uint256 outputBalanceAfter
        )
    {
        inputBalanceBefore = inputCurrency.balanceOfSelf();
        outputBalanceBefore = outputCurrency.balanceOfSelf();

        bytes memory data = plan.finalizeSwap(inputCurrency, outputCurrency, ActionConstants.MSG_SENDER);

        // send too much ETH to mimic slippage
        uint256 value = expectedAmountIn + 0.1 ether;
        router.executeActionsAndSweepExcessETH{value: value}(data);

        inputBalanceAfter = inputCurrency.balanceOfSelf();
        outputBalanceAfter = outputCurrency.balanceOfSelf();
    }
}
