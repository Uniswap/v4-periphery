// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {RoutingTestHelpers} from "../shared/RoutingTestHelpers.sol";
import {Planner} from "../shared/Planner.sol";
import {Actions} from "../../src/libraries/Actions.sol";
import {ActionConstants} from "../../src/libraries/ActionConstants.sol";
import {IV4Router} from "../../src/interfaces/IV4Router.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

/// @notice Exact output is all-or-nothing. A v4 swap can partial-fill when a pool runs out of
///         liquidity before the price limit; the router must revert `V4ExactOutputUnfilled` rather
///         than silently deliver less than the requested `amountOut`. These drive real exact-output
///         swaps through the router against a deliberately thin pool.
contract V4RouterExactOutputUnfilledTest is RoutingTestHelpers {
    PoolKey internal thinKey;

    function setUp() public {
        setupRouterCurrenciesAndPoolsWithLiquidity();
        plan = Planner.init();
        // liquidity sits in a single tick-spacing band, so a 1e18 exact-output request cannot fully
        // fill before the price leaves the band
        thinKey = _createThinPool(currency0, currency1, 500, 0, 60);
    }

    function test_exactOutputSingle_revertsOnUnderfill() public {
        // buy currency0 by selling currency1 (oneForZero); the thin band cannot deliver 1e18 out
        IV4Router.ExactOutputSingleParams memory params =
            IV4Router.ExactOutputSingleParams(thinKey, false, 1 ether, type(uint128).max, 0, bytes(""));
        plan = plan.add(Actions.SWAP_EXACT_OUT_SINGLE, abi.encode(params));
        bytes memory data = plan.finalizeSwap(currency1, currency0, ActionConstants.MSG_SENDER);

        vm.expectPartialRevert(IV4Router.V4ExactOutputUnfilled.selector);
        router.executeActions(data);
    }

    function test_exactOutput_multiHop_revertsOnUnderfill() public {
        // a 2-hop path currency2 -> currency1 -> currency0 whose final hop (currency1 -> currency0)
        // is the thin pool; the final hop cannot deliver 1e18 of currency0
        tokenPath.push(currency2);
        tokenPath.push(currency1);
        tokenPath.push(currency0);
        IV4Router.ExactOutputParams memory params = _getExactOutputParams(tokenPath, 1 ether);
        // route the final hop through the thin pool by overriding its fee/tickSpacing in the path
        params.path[1].fee = 500;
        params.path[1].tickSpacing = 60;

        plan = plan.add(Actions.SWAP_EXACT_OUT, abi.encode(params));
        bytes memory data = plan.finalizeSwap(currency2, currency0, ActionConstants.MSG_SENDER);

        vm.expectPartialRevert(IV4Router.V4ExactOutputUnfilled.selector);
        router.executeActions(data);
    }

    function test_exactOutputSingle_fullFillSucceeds() public {
        // the deep pool (key0) fully fills, unchanged by the new guard
        uint256 amountOut = 1 ether;
        IV4Router.ExactOutputSingleParams memory params =
            IV4Router.ExactOutputSingleParams(key0, true, uint128(amountOut), type(uint128).max, 0, bytes(""));
        plan = plan.add(Actions.SWAP_EXACT_OUT_SINGLE, abi.encode(params));

        (, uint256 outputBalanceBefore,, uint256 outputBalanceAfter) =
            _finalizeAndExecuteSwap(currency0, currency1, 2 ether);

        assertEq(outputBalanceAfter - outputBalanceBefore, amountOut, "exact output delivered in full");
        assertEq(currency0.balanceOf(address(router)), 0, "router holds no input residual");
        assertEq(currency1.balanceOf(address(router)), 0, "router holds no output residual");
    }

    function _createThinPool(Currency a, Currency b, uint24 fee, int24 lower, int24 upper)
        internal
        returns (PoolKey memory key)
    {
        if (Currency.unwrap(a) > Currency.unwrap(b)) (a, b) = (b, a);
        key = PoolKey(a, b, fee, 60, IHooks(address(0)));
        manager.initialize(key, SQRT_PRICE_1_1);
        MockERC20(Currency.unwrap(a)).approve(address(positionManager), type(uint256).max);
        MockERC20(Currency.unwrap(b)).approve(address(positionManager), type(uint256).max);
        positionManager.modifyLiquidity(key, ModifyLiquidityParams(lower, upper, 200 ether, 0), "0x");
    }
}
