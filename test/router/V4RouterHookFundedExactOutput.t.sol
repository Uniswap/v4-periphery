// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {RoutingTestHelpers} from "../shared/RoutingTestHelpers.sol";
import {Planner} from "../shared/Planner.sol";
import {Actions} from "../../src/libraries/Actions.sol";
import {ActionConstants} from "../../src/libraries/ActionConstants.sol";
import {IV4Router} from "../../src/interfaces/IV4Router.sol";
import {MockFullySubsidizingHook} from "../mocks/MockFullySubsidizingHook.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";

/// @notice A hook may fund the entire input of an exact-output swap, leaving the router a positive
///         output against an input delta of exactly zero. That is solvent — the hook settles the debt
///         inside the unlock — but it is a shape ordinary pools cannot produce, so the router used to
///         panic dividing by zero in the per-hop price guard, and to propagate the zero into an
///         upstream swap that PoolManager rejects with `SwapAmountCannotBeZero`.
contract V4RouterHookFundedExactOutputTest is RoutingTestHelpers {
    PoolKey internal hookKey;
    address internal hookAddr;

    function setUp() public {
        setupRouterCurrenciesAndPoolsWithLiquidity();
        plan = Planner.init();

        // the runtime code carries the manager immutable, so etching it preserves the constructor arg
        hookAddr = address(uint160(Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG));
        address impl = address(new MockFullySubsidizingHook(manager));
        vm.etch(hookAddr, impl.code);
        // etch copies runtime code but not storage, so the constructor's default does not carry over
        MockFullySubsidizingHook(hookAddr).setSubsidyBps(10_000);

        hookKey = createPoolWithLiquidity(currency0, currency1, hookAddr);
        // a second hooked pool, so a multihop path can have a funded hop that is not the last one
        createPoolWithLiquidity(currency1, currency2, hookAddr);

        // the hook pays the swapper's input out of its own balance
        MockERC20(Currency.unwrap(currency0)).mint(hookAddr, 2 ** 120);
        MockERC20(Currency.unwrap(currency1)).mint(hookAddr, 2 ** 120);
        MockERC20(Currency.unwrap(currency2)).mint(hookAddr, 2 ** 120);
        MockERC20(Currency.unwrap(currency3)).mint(hookAddr, 2 ** 120);
    }

    /// @notice Previously panicked 0x12 on `amountOutActual * PRECISION / amountIn`.
    function test_exactOutputSingle_hookFundsInput_withMinHopPrice_succeeds() public {
        uint128 amountOut = 1 ether;
        IV4Router.ExactOutputSingleParams memory params = IV4Router.ExactOutputSingleParams({
            poolKey: hookKey,
            zeroForOne: true,
            amountOut: amountOut,
            amountInMaximum: type(uint128).max,
            // realized price is infinite when the input is zero, so any finite bound must pass
            minHopPriceX36: type(uint256).max,
            hookData: bytes("")
        });
        plan = plan.add(Actions.SWAP_EXACT_OUT_SINGLE, abi.encode(params));

        (uint256 inputBefore, uint256 outputBefore, uint256 inputAfter, uint256 outputAfter) =
            _finalizeAndExecuteSwap(currency0, currency1, 0);

        assertEq(inputBefore, inputAfter);
        assertEq(outputAfter - outputBefore, amountOut);
    }

    /// @notice The zero-input path must still be reachable with the price guard disabled.
    function test_exactOutputSingle_hookFundsInput_noMinHopPrice_succeeds() public {
        uint128 amountOut = 1 ether;
        IV4Router.ExactOutputSingleParams memory params = IV4Router.ExactOutputSingleParams({
            poolKey: hookKey,
            zeroForOne: true,
            amountOut: amountOut,
            amountInMaximum: type(uint128).max,
            minHopPriceX36: 0,
            hookData: bytes("")
        });
        plan = plan.add(Actions.SWAP_EXACT_OUT_SINGLE, abi.encode(params));

        (uint256 inputBefore, uint256 outputBefore, uint256 inputAfter, uint256 outputAfter) =
            _finalizeAndExecuteSwap(currency0, currency1, 0);

        assertEq(inputBefore, inputAfter);
        assertEq(outputAfter - outputBefore, amountOut);
    }

    /// @notice Previously reverted `SwapAmountCannotBeZero`: the funded final hop propagated an
    ///         `amountOut` of zero into the upstream currency2 -> currency1 swap.
    function test_exactOutput_multiHop_hookFundsFinalHop_skipsUpstreamHops() public {
        uint128 amountOut = 1 ether;
        tokenPath.push(currency2);
        tokenPath.push(currency1);
        tokenPath.push(currency0);
        IV4Router.ExactOutputParams memory params = _getExactOutputParams(tokenPath, amountOut);
        // the final hop (currency1 -> currency0) is the fully subsidizing hook pool
        params.path[1].hooks = IHooks(hookAddr);

        plan = plan.add(Actions.SWAP_EXACT_OUT, abi.encode(params));

        (uint256 inputBefore, uint256 outputBefore, uint256 inputAfter, uint256 outputAfter) =
            _finalizeAndExecuteSwap(currency2, currency0, 0);

        assertEq(inputBefore, inputAfter);
        assertEq(outputAfter - outputBefore, amountOut);
    }

    /// @notice The multihop division is gated on array presence, so a non-empty `minHopPriceX36`
    ///         panicked on a funded hop even when that hop's own bound was zero.
    function test_exactOutput_multiHop_hookFundsFinalHop_withPerHopPrices_succeeds() public {
        uint128 amountOut = 1 ether;
        tokenPath.push(currency2);
        tokenPath.push(currency1);
        tokenPath.push(currency0);

        uint256[] memory minHopPriceX36 = new uint256[](2);
        minHopPriceX36[0] = 0;
        minHopPriceX36[1] = type(uint256).max;

        IV4Router.ExactOutputParams memory params = _getExactOutputParams(tokenPath, minHopPriceX36, amountOut);
        params.path[1].hooks = IHooks(hookAddr);

        plan = plan.add(Actions.SWAP_EXACT_OUT, abi.encode(params));

        (uint256 inputBefore, uint256 outputBefore, uint256 inputAfter, uint256 outputAfter) =
            _finalizeAndExecuteSwap(currency2, currency0, 0);

        assertEq(inputBefore, inputAfter);
        assertEq(outputAfter - outputBefore, amountOut);
    }

    /// @notice Documents current behavior. A hook paying MORE than the swap cost leaves the router a
    ///         credit on the input currency, which has no defined owner in a route. Negating a positive
    ///         delta wraps, so the cast rejects it. Unchanged by this fix, but pinned so a future change
    ///         cannot start silently accepting a surplus.
    function test_exactOutputSingle_hookOverpays_reverts() public {
        MockFullySubsidizingHook(hookAddr).setExtraWei(1);

        IV4Router.ExactOutputSingleParams memory params = IV4Router.ExactOutputSingleParams({
            poolKey: hookKey,
            zeroForOne: true,
            amountOut: 1 ether,
            amountInMaximum: type(uint128).max,
            minHopPriceX36: 0,
            hookData: bytes("")
        });
        plan = plan.add(Actions.SWAP_EXACT_OUT_SINGLE, abi.encode(params));
        bytes memory data = plan.finalizeSwap(currency0, currency1, ActionConstants.MSG_SENDER);

        vm.expectRevert(SafeCast.SafeCastOverflow.selector);
        router.executeActions(data);
    }

    /// @notice Over-funding is rejected from the multihop call site too, and in the opposite direction:
    ///         the funded hop here is currency1 -> currency0, i.e. oneForZero, exercising the other
    ///         branch of _swapInput's direction ternary. Documents current behavior.
    function test_exactOutput_multiHop_hookOverpays_reverts() public {
        MockFullySubsidizingHook(hookAddr).setExtraWei(1);

        tokenPath.push(currency2);
        tokenPath.push(currency1);
        tokenPath.push(currency0);
        IV4Router.ExactOutputParams memory params = _getExactOutputParams(tokenPath, 1 ether);
        params.path[1].hooks = IHooks(hookAddr);

        plan = plan.add(Actions.SWAP_EXACT_OUT, abi.encode(params));
        bytes memory data = plan.finalizeSwap(currency2, currency0, ActionConstants.MSG_SENDER);

        vm.expectRevert(SafeCast.SafeCastOverflow.selector);
        router.executeActions(data);
    }

    /// @notice The zero-input branch is a boundary, so pin it: with an unsatisfiable price bound only a
    ///         full subsidy clears the guard, because only then is the realized price infinite. Any
    ///         partial subsidy leaves a finite price that must still be enforced.
    function testFuzz_exactOutputSingle_onlyFullSubsidyClearsPriceBound(uint256 subsidyBps) public {
        subsidyBps = bound(subsidyBps, 0, 10_000);
        MockFullySubsidizingHook(hookAddr).setSubsidyBps(subsidyBps);

        IV4Router.ExactOutputSingleParams memory params = IV4Router.ExactOutputSingleParams({
            poolKey: hookKey,
            zeroForOne: true,
            amountOut: 1 ether,
            amountInMaximum: type(uint128).max,
            minHopPriceX36: type(uint256).max,
            hookData: bytes("")
        });
        plan = plan.add(Actions.SWAP_EXACT_OUT_SINGLE, abi.encode(params));
        bytes memory data = plan.finalizeSwap(currency0, currency1, ActionConstants.MSG_SENDER);

        if (subsidyBps == 10_000) {
            router.executeActions(data);
        } else {
            vm.expectPartialRevert(IV4Router.V4TooMuchRequestedPerHopSingle.selector);
            router.executeActions(data);
        }
    }

    /// @notice The other side of the boundary: any surplus at all, down to a single wei, is rejected.
    ///         Documents current behavior; the boundary itself is what this fix moved.
    function testFuzz_exactOutputSingle_anyOverfundingReverts(uint128 extraWei) public {
        extraWei = uint128(bound(extraWei, 1, 1 ether));
        MockFullySubsidizingHook(hookAddr).setExtraWei(extraWei);

        IV4Router.ExactOutputSingleParams memory params = IV4Router.ExactOutputSingleParams({
            poolKey: hookKey,
            zeroForOne: true,
            amountOut: 1 ether,
            amountInMaximum: type(uint128).max,
            minHopPriceX36: 0,
            hookData: bytes("")
        });
        plan = plan.add(Actions.SWAP_EXACT_OUT_SINGLE, abi.encode(params));
        bytes memory data = plan.finalizeSwap(currency0, currency1, ActionConstants.MSG_SENDER);

        vm.expectRevert(SafeCast.SafeCastOverflow.selector);
        router.executeActions(data);
    }

    /// @notice The break must also work from the middle of a path, not just the first iteration. A
    ///         3-hop route currency3 -> currency2 -> currency1 -> currency0 whose MIDDLE hop is funded:
    ///         the last hop executes normally, the funded hop stops the loop, and the first hop never
    ///         runs, so the caller spends no currency3.
    function test_exactOutput_threeHop_hookFundsMiddleHop_skipsRemainingHops() public {
        uint128 amountOut = 1 ether;
        tokenPath.push(currency3);
        tokenPath.push(currency2);
        tokenPath.push(currency1);
        tokenPath.push(currency0);
        IV4Router.ExactOutputParams memory params = _getExactOutputParams(tokenPath, amountOut);
        // path[1] is the currency2 -> currency1 hop, the middle one
        params.path[1].hooks = IHooks(hookAddr);

        plan = plan.add(Actions.SWAP_EXACT_OUT, abi.encode(params));

        (uint256 inputBefore, uint256 outputBefore, uint256 inputAfter, uint256 outputAfter) =
            _finalizeAndExecuteSwap(currency3, currency0, 0);

        assertEq(inputBefore, inputAfter);
        assertEq(outputAfter - outputBefore, amountOut);
    }

    /// @notice A funded hop must not weaken the all-or-nothing guarantee: the fill check runs before
    ///         the zero-input branch, so an underfilled funded hop still reverts.
    function test_exactOutputSingle_hookFundsInput_stillEnforcesFill() public {
        // liquidity sits above the current price, so a zeroForOne swap leaves the band immediately
        // and cannot deliver the requested output even though the hook would cover the input
        PoolKey memory thinHookKey = PoolKey(currency0, currency1, 500, 60, IHooks(hookAddr));
        manager.initialize(thinHookKey, SQRT_PRICE_1_1);
        positionManager.modifyLiquidity(thinHookKey, ModifyLiquidityParams(0, 60, 200 ether, 0), "0x");

        IV4Router.ExactOutputSingleParams memory params = IV4Router.ExactOutputSingleParams({
            poolKey: thinHookKey,
            zeroForOne: true,
            amountOut: 1 ether,
            amountInMaximum: type(uint128).max,
            minHopPriceX36: 0,
            hookData: bytes("")
        });
        plan = plan.add(Actions.SWAP_EXACT_OUT_SINGLE, abi.encode(params));
        bytes memory data = plan.finalizeSwap(currency0, currency1, ActionConstants.MSG_SENDER);

        vm.expectPartialRevert(IV4Router.V4ExactOutputUnfilled.selector);
        router.executeActions(data);
    }
}
