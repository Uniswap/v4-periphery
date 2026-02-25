// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {IV4Router} from "../../src/interfaces/IV4Router.sol";
import {RoutingTestHelpers} from "../shared/RoutingTestHelpers.sol";
import {Planner} from "../shared/Planner.sol";
import {Actions} from "../../src/libraries/Actions.sol";
import {ActionConstants} from "../../src/libraries/ActionConstants.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

contract V4RouterTest is RoutingTestHelpers {
    address alice = makeAddr("ALICE");

    function setUp() public {
        setupRouterCurrenciesAndPoolsWithLiquidity();
        plan = Planner.init();
    }

    /*//////////////////////////////////////////////////////////////
                        ERC20 -> ERC20 EXACT INPUT
    //////////////////////////////////////////////////////////////*/

    function test_swapExactInputSingle_revertsForAmountOut() public {
        uint256 amountIn = 1 ether;
        uint256 expectedAmountOut = 992054607780215625;

        // min amount out of 1 higher than the actual amount out
        IV4Router.ExactInputSingleParams memory params = IV4Router.ExactInputSingleParams(
            key0, true, uint128(amountIn), uint128(expectedAmountOut + 1), 0, bytes("")
        );

        plan = plan.add(Actions.SWAP_EXACT_IN_SINGLE, abi.encode(params));
        bytes memory data = plan.finalizeSwap(key0.currency0, key0.currency1, ActionConstants.MSG_SENDER);

        vm.expectRevert(
            abi.encodeWithSelector(IV4Router.V4TooLittleReceived.selector, expectedAmountOut + 1, expectedAmountOut)
        );
        router.executeActions(data);
    }

    function test_swapExactInputSingle_revertsForPerHopSlippage() public {
        uint256 amountIn = 1 ether;
        uint256 expectedAmountOut = 992054607780215625;

        uint256 expectedPrice = expectedAmountOut * 1e36 / amountIn;

        IV4Router.ExactInputSingleParams memory params =
            IV4Router.ExactInputSingleParams(key0, true, uint128(amountIn), 0, expectedPrice + 1, bytes(""));

        plan = plan.add(Actions.SWAP_EXACT_IN_SINGLE, abi.encode(params));
        bytes memory data = plan.finalizeSwap(key0.currency0, key0.currency1, ActionConstants.MSG_SENDER);

        vm.expectRevert(
            abi.encodeWithSelector(IV4Router.V4TooLittleReceivedPerHopSingle.selector, expectedPrice + 1, expectedPrice)
        );
        router.executeActions(data);
    }

    function test_swapExactInputSingle_succeedsForPerHopSlippage() public {
        uint256 amountIn = 1 ether;
        uint256 expectedAmountOut = 992054607780215625;

        uint256 expectedPrice = expectedAmountOut * 1e36 / amountIn;

        IV4Router.ExactInputSingleParams memory params = IV4Router.ExactInputSingleParams(
            key0, true, uint128(amountIn), uint128(expectedAmountOut), expectedPrice, bytes("")
        );

        plan = plan.add(Actions.SWAP_EXACT_IN_SINGLE, abi.encode(params));
        bytes memory data = plan.finalizeSwap(key0.currency0, key0.currency1, ActionConstants.MSG_SENDER);

        router.executeActions(data);
    }

    function test_swapExactInputSingle_zeroForOne_takeToMsgSender() public {
        uint256 amountIn = 1 ether;
        uint256 expectedAmountOut = 992054607780215625;

        IV4Router.ExactInputSingleParams memory params =
            IV4Router.ExactInputSingleParams(key0, true, uint128(amountIn), 0, 0, bytes(""));

        plan = plan.add(Actions.SWAP_EXACT_IN_SINGLE, abi.encode(params));
        (
            uint256 inputBalanceBefore,
            uint256 outputBalanceBefore,
            uint256 inputBalanceAfter,
            uint256 outputBalanceAfter
        ) = _finalizeAndExecuteSwap(key0.currency0, key0.currency1, amountIn);

        assertEq(currency0.balanceOf(address(router)), 0);
        assertEq(currency1.balanceOf(address(router)), 0);

        assertEq(inputBalanceBefore - inputBalanceAfter, amountIn);
        assertEq(outputBalanceAfter - outputBalanceBefore, expectedAmountOut);
    }

    function test_swapExactInputSingle_zeroForOne_takeToRecipient() public {
        uint256 amountIn = 1 ether;
        uint256 expectedAmountOut = 992054607780215625;

        IV4Router.ExactInputSingleParams memory params =
            IV4Router.ExactInputSingleParams(key0, true, uint128(amountIn), 0, 0, bytes(""));

        plan = plan.add(Actions.SWAP_EXACT_IN_SINGLE, abi.encode(params));

        uint256 aliceOutputBalanceBefore = key0.currency1.balanceOf(alice);

        // swap with alice as the take recipient
        (
            uint256 inputBalanceBefore,
            uint256 outputBalanceBefore,
            uint256 inputBalanceAfter,
            uint256 outputBalanceAfter
        ) = _finalizeAndExecuteSwap(key0.currency0, key0.currency1, amountIn, alice);

        uint256 aliceOutputBalanceAfter = key0.currency1.balanceOf(alice);

        assertEq(currency0.balanceOf(address(router)), 0);
        assertEq(currency1.balanceOf(address(router)), 0);

        assertEq(inputBalanceBefore - inputBalanceAfter, amountIn);
        // this contract's output balance has not changed because funds went to alice
        assertEq(outputBalanceAfter, outputBalanceBefore);
        assertEq(aliceOutputBalanceAfter - aliceOutputBalanceBefore, expectedAmountOut);
    }

    // This is not a real use-case in isolation, but will be used in the UniversalRouter if a v4
    // swap is before another swap on v2/v3
    function test_swapExactInputSingle_zeroForOne_takeAllToRouter() public {
        uint256 amountIn = 1 ether;
        uint256 expectedAmountOut = 992054607780215625;

        IV4Router.ExactInputSingleParams memory params =
            IV4Router.ExactInputSingleParams(key0, true, uint128(amountIn), 0, 0, bytes(""));

        plan = plan.add(Actions.SWAP_EXACT_IN_SINGLE, abi.encode(params));

        // the router holds no funds before
        assertEq(currency0.balanceOf(address(router)), 0);
        assertEq(currency1.balanceOf(address(router)), 0);

        // swap with the router as the take recipient
        (
            uint256 inputBalanceBefore,
            uint256 outputBalanceBefore,
            uint256 inputBalanceAfter,
            uint256 outputBalanceAfter
        ) = _finalizeAndExecuteSwap(key0.currency0, key0.currency1, amountIn, ActionConstants.ADDRESS_THIS);

        // the output tokens have been left in the router
        assertEq(currency0.balanceOf(address(router)), 0);
        assertEq(currency1.balanceOf(address(router)), expectedAmountOut);

        assertEq(inputBalanceBefore - inputBalanceAfter, amountIn);
        // this contract's output balance has not changed because funds went to the router
        assertEq(outputBalanceAfter, outputBalanceBefore);
    }

    // This is not a real use-case in isolation, but will be used in the UniversalRouter if a v4
    // swap is before another swap on v2/v3
    function test_swapExactInputSingle_zeroForOne_takeToRouter() public {
        uint256 amountIn = 1 ether;
        uint256 expectedAmountOut = 992054607780215625;

        IV4Router.ExactInputSingleParams memory params =
            IV4Router.ExactInputSingleParams(key0, true, uint128(amountIn), 0, 0, bytes(""));

        plan = plan.add(Actions.SWAP_EXACT_IN_SINGLE, abi.encode(params));
        plan = plan.add(Actions.SETTLE_ALL, abi.encode(key0.currency0, expectedAmountOut * 12 / 10));
        // take the entire open delta to the router's address
        plan = plan.add(
            Actions.TAKE, abi.encode(key0.currency1, ActionConstants.ADDRESS_THIS, ActionConstants.OPEN_DELTA)
        );
        bytes memory data = plan.encode();

        // the router holds no funds before
        assertEq(currency0.balanceOf(address(router)), 0);
        assertEq(currency1.balanceOf(address(router)), 0);
        uint256 inputBalanceBefore = key0.currency0.balanceOfSelf();
        uint256 outputBalanceBefore = key0.currency1.balanceOfSelf();

        router.executeActions(data);

        // the output tokens have been left in the router
        assertEq(currency0.balanceOf(address(router)), 0);
        assertEq(currency1.balanceOf(address(router)), expectedAmountOut);
        uint256 inputBalanceAfter = key0.currency0.balanceOfSelf();
        uint256 outputBalanceAfter = key0.currency1.balanceOfSelf();

        assertEq(inputBalanceBefore - inputBalanceAfter, amountIn);
        // this contract's output balance has not changed because funds went to the router
        assertEq(outputBalanceAfter, outputBalanceBefore);
    }

    function test_swapExactInputSingle_oneForZero() public {
        uint256 amountIn = 1 ether;
        uint256 expectedAmountOut = 992054607780215625;

        IV4Router.ExactInputSingleParams memory params =
            IV4Router.ExactInputSingleParams(key0, false, uint128(amountIn), 0, 0, bytes(""));
        plan = plan.add(Actions.SWAP_EXACT_IN_SINGLE, abi.encode(params));

        (
            uint256 inputBalanceBefore,
            uint256 outputBalanceBefore,
            uint256 inputBalanceAfter,
            uint256 outputBalanceAfter
        ) = _finalizeAndExecuteSwap(key0.currency1, key0.currency0, amountIn);

        assertEq(currency0.balanceOf(address(router)), 0);
        assertEq(currency1.balanceOf(address(router)), 0);

        assertEq(inputBalanceBefore - inputBalanceAfter, amountIn);
        assertEq(outputBalanceAfter - outputBalanceBefore, expectedAmountOut);
    }

    function test_swapExactInput_revertsForAmountOut() public {
        uint256 amountIn = 1 ether;
        uint256 expectedAmountOut = 992054607780215625;

        tokenPath.push(currency0);
        tokenPath.push(currency1);
        IV4Router.ExactInputParams memory params = _getExactInputParams(tokenPath, amountIn);
        params.amountOutMinimum = uint128(expectedAmountOut + 1);

        plan = plan.add(Actions.SWAP_EXACT_IN, abi.encode(params));
        bytes memory data = plan.finalizeSwap(key0.currency0, key0.currency1, ActionConstants.MSG_SENDER);

        vm.expectRevert(
            abi.encodeWithSelector(IV4Router.V4TooLittleReceived.selector, 992054607780215625 + 1, 992054607780215625)
        );
        router.executeActions(data);
    }

    function test_swapExactInput_revertsForAmountOutPerHop() public {
        uint256 amountIn = 1 ether;
        uint256 expectedAmountOut = 992054607780215625;

        uint256 expectedPrice = expectedAmountOut * 1e36 / amountIn;
        uint256[] memory maxSlippages = new uint256[](1);
        uint256 minPrice = expectedPrice + 1;
        maxSlippages[0] = minPrice;

        tokenPath.push(currency0);
        tokenPath.push(currency1);
        IV4Router.ExactInputParams memory params = _getExactInputParams(tokenPath, maxSlippages, amountIn);
        params.amountOutMinimum = uint128(0);

        plan = plan.add(Actions.SWAP_EXACT_IN, abi.encode(params));
        bytes memory data = plan.finalizeSwap(key0.currency0, key0.currency1, ActionConstants.MSG_SENDER);

        vm.expectRevert(
            abi.encodeWithSelector(IV4Router.V4TooLittleReceivedPerHop.selector, 0, minPrice, expectedPrice)
        );
        router.executeActions(data);
    }

    function test_swapExactInput_succeedsForAmountOutPerHop() public {
        uint256 amountIn = 1 ether;
        uint256 expectedAmountOut = 992054607780215625;

        uint256 expectedPrice = expectedAmountOut * 1e36 / amountIn;
        uint256[] memory maxSlippages = new uint256[](1);
        uint256 maxSlippage = expectedPrice;
        maxSlippages[0] = maxSlippage;

        tokenPath.push(currency0);
        tokenPath.push(currency1);
        IV4Router.ExactInputParams memory params = _getExactInputParams(tokenPath, maxSlippages, amountIn);
        params.amountOutMinimum = uint128(expectedAmountOut);

        plan = plan.add(Actions.SWAP_EXACT_IN, abi.encode(params));
        bytes memory data = plan.finalizeSwap(key0.currency0, key0.currency1, ActionConstants.MSG_SENDER);

        router.executeActions(data);
    }

    // Regression test: with PRECISION = 1e18, the price truncates to 0 for extreme ratios, disabling the check.
    function test_swapExactInput_extremeRatioPerHopSlippage() public {
        // Create a pool at extreme price: ~1e22 token1 per token0 (simulates WBTC/PEPE-like ratio)
        int24 extremeTick = 506520;
        uint160 extremeSqrtPrice = TickMath.getSqrtPriceAtTick(extremeTick);

        MockERC20 tokenA = new MockERC20("A", "A", 18);
        MockERC20 tokenB = new MockERC20("B", "B", 18);
        tokenA.mint(address(this), 2 ** 128);
        tokenB.mint(address(this), 2 ** 128);
        tokenA.approve(address(router), type(uint256).max);
        tokenB.approve(address(router), type(uint256).max);
        tokenA.approve(address(positionManager), type(uint256).max);
        tokenB.approve(address(positionManager), type(uint256).max);

        Currency currA = Currency.wrap(address(tokenA));
        Currency currB = Currency.wrap(address(tokenB));
        if (Currency.unwrap(currA) > Currency.unwrap(currB)) {
            (currA, currB) = (currB, currA);
        }

        PoolKey memory extremeKey = PoolKey(currA, currB, 3000, 60, IHooks(address(0)));
        manager.initialize(extremeKey, extremeSqrtPrice);
        positionManager.modifyLiquidity(
            extremeKey, ModifyLiquidityParams(extremeTick - 600, extremeTick + 600, 100 ether, 0), "0x"
        );

        uint256 amountIn = 1e8;
        Currency[] memory path = new Currency[](2);
        path[0] = currA;
        path[1] = currB;

        // Snapshot state so the first swap doesn't drain liquidity for the second
        uint256 snap = vm.snapshotState();

        // First swap without per-hop slippage to discover actual amountOut
        IV4Router.ExactInputParams memory params = _getExactInputParams(path, amountIn);
        plan = Planner.init();
        plan = plan.add(Actions.SWAP_EXACT_IN, abi.encode(params));
        bytes memory data = plan.finalizeSwap(currA, currB, ActionConstants.MSG_SENDER);

        uint256 outputBefore = currB.balanceOfSelf();
        router.executeActions(data);
        uint256 actualAmountOut = currB.balanceOfSelf() - outputBefore;

        // With output/input formula: price is large for this direction, no truncation concern.
        // The precision concern applies in the reverse direction (tiny output, huge input).
        uint256 expectedPrice = actualAmountOut * 1e36 / amountIn;
        assertGt(expectedPrice, 0, "price should be non-zero");

        // Restore state for the slippage test
        vm.revertToState(snap);

        // Verify the per-hop slippage check fires for extreme ratio pairs
        uint256[] memory maxSlippages = new uint256[](1);
        maxSlippages[0] = expectedPrice + 1;

        IV4Router.ExactInputParams memory params2 = _getExactInputParams(path, maxSlippages, amountIn);
        params2.amountOutMinimum = 0;
        plan = Planner.init();
        plan = plan.add(Actions.SWAP_EXACT_IN, abi.encode(params2));
        data = plan.finalizeSwap(currA, currB, ActionConstants.MSG_SENDER);

        vm.expectRevert(
            abi.encodeWithSelector(IV4Router.V4TooLittleReceivedPerHop.selector, 0, expectedPrice + 1, expectedPrice)
        );
        router.executeActions(data);
    }

    function test_swapExactIn_1Hop_zeroForOne() public {
        uint256 amountIn = 1 ether;
        uint256 expectedAmountOut = 992054607780215625;

        tokenPath.push(currency0);
        tokenPath.push(currency1);
        IV4Router.ExactInputParams memory params = _getExactInputParams(tokenPath, amountIn);
        plan = plan.add(Actions.SWAP_EXACT_IN, abi.encode(params));

        (
            uint256 inputBalanceBefore,
            uint256 outputBalanceBefore,
            uint256 inputBalanceAfter,
            uint256 outputBalanceAfter
        ) = _finalizeAndExecuteSwap(currency0, currency1, amountIn);

        assertEq(currency0.balanceOf(address(router)), 0);
        assertEq(currency1.balanceOf(address(router)), 0);

        assertEq(inputBalanceBefore - inputBalanceAfter, amountIn);
        assertEq(outputBalanceAfter - outputBalanceBefore, expectedAmountOut);
    }

    function test_swapExactIn_1Hop_oneForZero() public {
        uint256 amountIn = 1 ether;
        uint256 expectedAmountOut = 992054607780215625;

        tokenPath.push(currency1);
        tokenPath.push(currency0);
        IV4Router.ExactInputParams memory params = _getExactInputParams(tokenPath, amountIn);

        plan = plan.add(Actions.SWAP_EXACT_IN, abi.encode(params));

        (
            uint256 inputBalanceBefore,
            uint256 outputBalanceBefore,
            uint256 inputBalanceAfter,
            uint256 outputBalanceAfter
        ) = _finalizeAndExecuteSwap(currency1, currency0, amountIn);

        assertEq(currency0.balanceOf(address(router)), 0);
        assertEq(currency1.balanceOf(address(router)), 0);

        assertEq(inputBalanceBefore - inputBalanceAfter, amountIn);
        assertEq(outputBalanceAfter - outputBalanceBefore, expectedAmountOut);
    }

    function test_swapExactIn_2Hops() public {
        uint256 amountIn = 1 ether;
        uint256 expectedAmountOut = 984211133872795298;

        tokenPath.push(currency0);
        tokenPath.push(currency1);
        tokenPath.push(currency2);
        IV4Router.ExactInputParams memory params = _getExactInputParams(tokenPath, amountIn);

        plan = plan.add(Actions.SWAP_EXACT_IN, abi.encode(params));

        uint256 intermediateBalanceBefore = currency1.balanceOfSelf();

        (
            uint256 inputBalanceBefore,
            uint256 outputBalanceBefore,
            uint256 inputBalanceAfter,
            uint256 outputBalanceAfter
        ) = _finalizeAndExecuteSwap(currency0, currency2, amountIn);

        // check intermediate token balances
        assertEq(intermediateBalanceBefore, currency1.balanceOfSelf());
        assertEq(currency0.balanceOf(address(router)), 0);
        assertEq(currency1.balanceOf(address(router)), 0);
        assertEq(currency2.balanceOf(address(router)), 0);

        assertEq(inputBalanceBefore - inputBalanceAfter, amountIn);
        assertEq(outputBalanceAfter - outputBalanceBefore, expectedAmountOut);
    }

    function test_swapExactIn_3Hops() public {
        uint256 amountIn = 1 ether;
        uint256 expectedAmountOut = 976467664490096191;

        tokenPath.push(currency0);
        tokenPath.push(currency1);
        tokenPath.push(currency2);
        tokenPath.push(currency3);
        IV4Router.ExactInputParams memory params = _getExactInputParams(tokenPath, amountIn);

        plan = plan.add(Actions.SWAP_EXACT_IN, abi.encode(params));

        (
            uint256 inputBalanceBefore,
            uint256 outputBalanceBefore,
            uint256 inputBalanceAfter,
            uint256 outputBalanceAfter
        ) = _finalizeAndExecuteSwap(currency0, currency3, amountIn);

        // check intermediate tokens werent left in the router
        assertEq(currency0.balanceOf(address(router)), 0);
        assertEq(currency1.balanceOf(address(router)), 0);
        assertEq(currency2.balanceOf(address(router)), 0);
        assertEq(currency3.balanceOf(address(router)), 0);

        assertEq(inputBalanceBefore - inputBalanceAfter, amountIn);
        assertEq(outputBalanceAfter - outputBalanceBefore, expectedAmountOut);
    }

    function test_swap_settleRouterBalance_swapOpenDelta() public {
        uint256 amountIn = 1 ether;
        uint256 expectedAmountOut = 992054607780215625;

        key0.currency0.transfer(address(router), amountIn);

        // amount in of 0 to show it should use the open delta
        IV4Router.ExactInputSingleParams memory params =
            IV4Router.ExactInputSingleParams(key0, true, ActionConstants.OPEN_DELTA, 0, 0, bytes(""));

        plan = plan.add(Actions.SETTLE, abi.encode(key0.currency0, ActionConstants.CONTRACT_BALANCE, false));
        plan = plan.add(Actions.SWAP_EXACT_IN_SINGLE, abi.encode(params));
        plan = plan.add(Actions.TAKE_ALL, abi.encode(key0.currency1, MIN_TAKE_AMOUNT));

        bytes memory data = plan.encode();

        uint256 callerInputBefore = key0.currency0.balanceOfSelf();
        uint256 routerInputBefore = key0.currency0.balanceOf(address(router));
        uint256 callerOutputBefore = key0.currency1.balanceOfSelf();
        router.executeActions(data);

        uint256 callerInputAfter = key0.currency0.balanceOfSelf();
        uint256 routerInputAfter = key0.currency0.balanceOf(address(router));
        uint256 callerOutputAfter = key0.currency1.balanceOfSelf();

        // caller didnt pay, router paid, caller received the output
        assertEq(callerInputBefore, callerInputAfter);
        assertEq(routerInputBefore - amountIn, routerInputAfter);
        assertEq(callerOutputBefore + expectedAmountOut, callerOutputAfter);
    }

    /*//////////////////////////////////////////////////////////////
                ETH -> ERC20 and ERC20 -> ETH EXACT INPUT
    //////////////////////////////////////////////////////////////*/

    function test_nativeIn_swapExactInputSingle() public {
        uint256 amountIn = 1 ether;
        uint256 expectedAmountOut = 992054607780215625;

        IV4Router.ExactInputSingleParams memory params =
            IV4Router.ExactInputSingleParams(nativeKey, true, uint128(amountIn), 0, 0, bytes(""));

        plan = plan.add(Actions.SWAP_EXACT_IN_SINGLE, abi.encode(params));

        (
            uint256 inputBalanceBefore,
            uint256 outputBalanceBefore,
            uint256 inputBalanceAfter,
            uint256 outputBalanceAfter
        ) = _finalizeAndExecuteSwap(nativeKey.currency0, nativeKey.currency1, amountIn);

        assertEq(nativeKey.currency0.balanceOf(address(router)), 0);
        assertEq(nativeKey.currency1.balanceOf(address(router)), 0);

        assertEq(inputBalanceBefore - inputBalanceAfter, amountIn);
        assertEq(outputBalanceAfter - outputBalanceBefore, expectedAmountOut);
    }

    function test_nativeOut_swapExactInputSingle() public {
        uint256 amountIn = 1 ether;
        uint256 expectedAmountOut = 992054607780215625;

        // native output means we need !zeroForOne
        IV4Router.ExactInputSingleParams memory params =
            IV4Router.ExactInputSingleParams(nativeKey, false, uint128(amountIn), 0, 0, bytes(""));

        plan = plan.add(Actions.SWAP_EXACT_IN_SINGLE, abi.encode(params));

        (
            uint256 inputBalanceBefore,
            uint256 outputBalanceBefore,
            uint256 inputBalanceAfter,
            uint256 outputBalanceAfter
        ) = _finalizeAndExecuteSwap(nativeKey.currency1, nativeKey.currency0, amountIn);

        assertEq(nativeKey.currency0.balanceOf(address(router)), 0);
        assertEq(nativeKey.currency1.balanceOf(address(router)), 0);

        assertEq(inputBalanceBefore - inputBalanceAfter, amountIn);
        assertEq(outputBalanceAfter - outputBalanceBefore, expectedAmountOut);
    }

    function test_nativeIn_swapExactIn_1Hop() public {
        uint256 amountIn = 1 ether;
        uint256 expectedAmountOut = 992054607780215625;

        tokenPath.push(CurrencyLibrary.ADDRESS_ZERO);
        tokenPath.push(nativeKey.currency1);
        IV4Router.ExactInputParams memory params = _getExactInputParams(tokenPath, amountIn);
        plan = plan.add(Actions.SWAP_EXACT_IN, abi.encode(params));

        (
            uint256 inputBalanceBefore,
            uint256 outputBalanceBefore,
            uint256 inputBalanceAfter,
            uint256 outputBalanceAfter
        ) = _finalizeAndExecuteSwap(CurrencyLibrary.ADDRESS_ZERO, nativeKey.currency1, amountIn);

        assertEq(nativeKey.currency0.balanceOf(address(router)), 0);
        assertEq(nativeKey.currency1.balanceOf(address(router)), 0);

        assertEq(inputBalanceBefore - inputBalanceAfter, amountIn);
        assertEq(outputBalanceAfter - outputBalanceBefore, expectedAmountOut);
    }

    function test_nativeOut_swapExactIn_1Hop() public {
        uint256 amountIn = 1 ether;
        uint256 expectedAmountOut = 992054607780215625;

        tokenPath.push(nativeKey.currency1);
        tokenPath.push(CurrencyLibrary.ADDRESS_ZERO);
        IV4Router.ExactInputParams memory params = _getExactInputParams(tokenPath, amountIn);

        plan = plan.add(Actions.SWAP_EXACT_IN, abi.encode(params));

        (
            uint256 inputBalanceBefore,
            uint256 outputBalanceBefore,
            uint256 inputBalanceAfter,
            uint256 outputBalanceAfter
        ) = _finalizeAndExecuteSwap(nativeKey.currency1, CurrencyLibrary.ADDRESS_ZERO, amountIn);

        assertEq(nativeKey.currency0.balanceOf(address(router)), 0);
        assertEq(nativeKey.currency1.balanceOf(address(router)), 0);

        assertEq(inputBalanceBefore - inputBalanceAfter, amountIn);
        assertEq(outputBalanceAfter - outputBalanceBefore, expectedAmountOut);
    }

    function test_nativeIn_swapExactIn_2Hops() public {
        uint256 amountIn = 1 ether;
        uint256 expectedAmountOut = 984211133872795298;

        // the initialized nativeKey is (native, currency0)
        tokenPath.push(CurrencyLibrary.ADDRESS_ZERO);
        tokenPath.push(currency0);
        tokenPath.push(currency1);
        IV4Router.ExactInputParams memory params = _getExactInputParams(tokenPath, amountIn);

        plan = plan.add(Actions.SWAP_EXACT_IN, abi.encode(params));

        uint256 intermediateBalanceBefore = currency0.balanceOfSelf();

        (
            uint256 inputBalanceBefore,
            uint256 outputBalanceBefore,
            uint256 inputBalanceAfter,
            uint256 outputBalanceAfter
        ) = _finalizeAndExecuteSwap(CurrencyLibrary.ADDRESS_ZERO, currency1, amountIn);

        // check intermediate token balances
        assertEq(intermediateBalanceBefore, currency0.balanceOfSelf());

        assertEq(nativeKey.currency0.balanceOf(address(router)), 0);
        assertEq(nativeKey.currency1.balanceOf(address(router)), 0);
        assertEq(currency1.balanceOf(address(router)), 0);

        assertEq(inputBalanceBefore - inputBalanceAfter, amountIn);
        assertEq(outputBalanceAfter - outputBalanceBefore, expectedAmountOut);
    }

    function test_nativeOut_swapExactIn_2Hops() public {
        uint256 amountIn = 1 ether;
        uint256 expectedAmountOut = 984211133872795298;

        // the initialized nativeKey is (native, currency0)
        tokenPath.push(currency1);
        tokenPath.push(currency0);
        tokenPath.push(CurrencyLibrary.ADDRESS_ZERO);
        IV4Router.ExactInputParams memory params = _getExactInputParams(tokenPath, amountIn);

        plan = plan.add(Actions.SWAP_EXACT_IN, abi.encode(params));

        uint256 intermediateBalanceBefore = currency0.balanceOfSelf();

        (
            uint256 inputBalanceBefore,
            uint256 outputBalanceBefore,
            uint256 inputBalanceAfter,
            uint256 outputBalanceAfter
        ) = _finalizeAndExecuteSwap(currency1, CurrencyLibrary.ADDRESS_ZERO, amountIn);

        // check intermediate token balances
        assertEq(intermediateBalanceBefore, currency0.balanceOfSelf());
        assertEq(nativeKey.currency0.balanceOf(address(router)), 0);
        assertEq(nativeKey.currency1.balanceOf(address(router)), 0);
        assertEq(currency1.balanceOf(address(router)), 0);

        assertEq(inputBalanceBefore - inputBalanceAfter, amountIn);
        assertEq(outputBalanceAfter - outputBalanceBefore, expectedAmountOut);
    }

    function test_swap_nativeIn_settleRouterBalance_swapOpenDelta() public {
        uint256 amountIn = 1 ether;
        uint256 expectedAmountOut = 992054607780215625;

        nativeKey.currency0.transfer(address(router), amountIn);

        // amount in of 0 to show it should use the open delta
        IV4Router.ExactInputSingleParams memory params =
            IV4Router.ExactInputSingleParams(nativeKey, true, ActionConstants.OPEN_DELTA, 0, 0, bytes(""));

        plan = plan.add(Actions.SETTLE, abi.encode(nativeKey.currency0, ActionConstants.CONTRACT_BALANCE, false));
        plan = plan.add(Actions.SWAP_EXACT_IN_SINGLE, abi.encode(params));
        plan = plan.add(Actions.TAKE_ALL, abi.encode(nativeKey.currency1, MIN_TAKE_AMOUNT));

        bytes memory data = plan.encode();

        uint256 callerInputBefore = nativeKey.currency0.balanceOfSelf();
        uint256 routerInputBefore = nativeKey.currency0.balanceOf(address(router));
        uint256 callerOutputBefore = nativeKey.currency1.balanceOfSelf();
        router.executeActions(data);

        uint256 callerInputAfter = nativeKey.currency0.balanceOfSelf();
        uint256 routerInputAfter = nativeKey.currency0.balanceOf(address(router));
        uint256 callerOutputAfter = nativeKey.currency1.balanceOfSelf();

        // caller didnt pay, router paid, caller received the output
        assertEq(callerInputBefore, callerInputAfter);
        assertEq(routerInputBefore - amountIn, routerInputAfter);
        assertEq(callerOutputBefore + expectedAmountOut, callerOutputAfter);
    }

    /*//////////////////////////////////////////////////////////////å
                        ERC20 -> ERC20 EXACT OUTPUT
    //////////////////////////////////////////////////////////////*/

    function test_swapExactOutputSingle_revertsForAmountIn() public {
        uint256 amountOut = 1 ether;
        uint256 expectedAmountIn = 1008049273448486163;

        IV4Router.ExactOutputSingleParams memory params = IV4Router.ExactOutputSingleParams(
            key0, true, uint128(amountOut), uint128(expectedAmountIn - 1), 0, bytes("")
        );

        plan = plan.add(Actions.SWAP_EXACT_OUT_SINGLE, abi.encode(params));
        bytes memory data = plan.finalizeSwap(key0.currency0, key0.currency1, ActionConstants.MSG_SENDER);

        vm.expectRevert(
            abi.encodeWithSelector(IV4Router.V4TooMuchRequested.selector, expectedAmountIn - 1, expectedAmountIn)
        );
        router.executeActions(data);
    }

    function test_swapExactOutputSingle_revertsForPerHopSlippage() public {
        uint256 amountOut = 1 ether;
        uint256 expectedAmountIn = 1008049273448486163;

        uint256 expectedPrice = amountOut * 1e36 / expectedAmountIn;

        IV4Router.ExactOutputSingleParams memory params = IV4Router.ExactOutputSingleParams(
            key0, true, uint128(amountOut), type(uint128).max, expectedPrice + 1, bytes("")
        );

        plan = plan.add(Actions.SWAP_EXACT_OUT_SINGLE, abi.encode(params));
        bytes memory data = plan.finalizeSwap(key0.currency0, key0.currency1, ActionConstants.MSG_SENDER);

        vm.expectRevert(
            abi.encodeWithSelector(IV4Router.V4TooMuchRequestedPerHopSingle.selector, expectedPrice + 1, expectedPrice)
        );
        router.executeActions(data);
    }

    function test_swapExactOutputSingle_succeedsForPerHopSlippage() public {
        uint256 amountOut = 1 ether;
        uint256 expectedAmountIn = 1008049273448486163;

        uint256 expectedPrice = amountOut * 1e36 / expectedAmountIn;

        IV4Router.ExactOutputSingleParams memory params = IV4Router.ExactOutputSingleParams(
            key0, true, uint128(amountOut), type(uint128).max, expectedPrice, bytes("")
        );

        plan = plan.add(Actions.SWAP_EXACT_OUT_SINGLE, abi.encode(params));
        bytes memory data = plan.finalizeSwap(key0.currency0, key0.currency1, ActionConstants.MSG_SENDER);

        router.executeActions(data);
    }

    function test_swapExactOutputSingle_zeroForOne() public {
        uint256 amountOut = 1 ether;
        uint256 expectedAmountIn = 1008049273448486163;

        IV4Router.ExactOutputSingleParams memory params = IV4Router.ExactOutputSingleParams(
            key0, true, uint128(amountOut), uint128(expectedAmountIn + 1), 0, bytes("")
        );

        plan = plan.add(Actions.SWAP_EXACT_OUT_SINGLE, abi.encode(params));

        (
            uint256 inputBalanceBefore,
            uint256 outputBalanceBefore,
            uint256 inputBalanceAfter,
            uint256 outputBalanceAfter
        ) = _finalizeAndExecuteSwap(key0.currency0, key0.currency1, expectedAmountIn);

        assertEq(currency0.balanceOf(address(router)), 0);
        assertEq(currency1.balanceOf(address(router)), 0);

        assertEq(inputBalanceBefore - inputBalanceAfter, expectedAmountIn);
        assertEq(outputBalanceAfter - outputBalanceBefore, amountOut);
    }

    function test_swapExactOutputSingle_oneForZero() public {
        uint256 amountOut = 1 ether;
        uint256 expectedAmountIn = 1008049273448486163;

        IV4Router.ExactOutputSingleParams memory params = IV4Router.ExactOutputSingleParams(
            key0, false, uint128(amountOut), uint128(expectedAmountIn + 1), 0, bytes("")
        );

        plan = plan.add(Actions.SWAP_EXACT_OUT_SINGLE, abi.encode(params));

        (
            uint256 inputBalanceBefore,
            uint256 outputBalanceBefore,
            uint256 inputBalanceAfter,
            uint256 outputBalanceAfter
        ) = _finalizeAndExecuteSwap(key0.currency1, key0.currency0, expectedAmountIn);

        assertEq(currency0.balanceOf(address(router)), 0);
        assertEq(currency1.balanceOf(address(router)), 0);

        assertEq(inputBalanceBefore - inputBalanceAfter, expectedAmountIn);
        assertEq(outputBalanceAfter - outputBalanceBefore, amountOut);
    }

    function test_swapExactOutputSingle_swapOpenDelta() public {
        uint256 expectedAmountIn = 1008049273448486163;

        IV4Router.ExactOutputSingleParams memory params = IV4Router.ExactOutputSingleParams(
            key0, true, ActionConstants.OPEN_DELTA, uint128(expectedAmountIn + 1), 0, bytes("")
        );

        plan = plan.add(Actions.TAKE, abi.encode(key0.currency1, ActionConstants.ADDRESS_THIS, 1 ether));
        plan = plan.add(Actions.SWAP_EXACT_OUT_SINGLE, abi.encode(params));
        plan = plan.add(Actions.SETTLE, abi.encode(key0.currency0, ActionConstants.OPEN_DELTA, true));

        bytes memory data = plan.encode();

        uint256 callerInputBefore = key0.currency0.balanceOfSelf();
        uint256 routerInputBefore = key0.currency1.balanceOfSelf();
        uint256 callerOutputBefore = key0.currency1.balanceOfSelf();

        router.executeActions(data);

        uint256 callerInputAfter = key0.currency0.balanceOfSelf();
        uint256 routerInputAfter = key0.currency1.balanceOfSelf();
        uint256 callerOutputAfter = key0.currency1.balanceOfSelf();

        // caller paid
        assertEq(callerInputBefore - expectedAmountIn, callerInputAfter);
        assertEq(routerInputBefore, routerInputAfter);
        assertEq(callerOutputBefore, callerOutputAfter);
    }

    function test_swapExactOut_revertsForAmountIn() public {
        uint256 amountOut = 1 ether;
        uint256 expectedAmountIn = 1008049273448486163;

        tokenPath.push(currency0);
        tokenPath.push(currency1);
        IV4Router.ExactOutputParams memory params = _getExactOutputParams(tokenPath, amountOut);
        params.amountInMaximum = uint128(expectedAmountIn - 1);

        plan = plan.add(Actions.SWAP_EXACT_OUT, abi.encode(params));
        bytes memory data = plan.finalizeSwap(key0.currency0, key0.currency1, ActionConstants.MSG_SENDER);

        vm.expectRevert(
            abi.encodeWithSelector(IV4Router.V4TooMuchRequested.selector, expectedAmountIn - 1, expectedAmountIn)
        );
        router.executeActions(data);
    }

    function test_swapExactOut_revertsForAmountInPerHop() public {
        uint256 amountOut = 1 ether;
        uint256 expectedAmountIn = 1008049273448486163;

        uint256 expectedPrice = amountOut * 1e36 / expectedAmountIn;
        uint256[] memory maxSlippages = new uint256[](1);
        uint256 minPrice = expectedPrice + 1;
        maxSlippages[0] = minPrice;

        tokenPath.push(currency0);
        tokenPath.push(currency1);
        IV4Router.ExactOutputParams memory params = _getExactOutputParams(tokenPath, maxSlippages, amountOut);
        params.amountInMaximum = type(uint128).max;

        plan = plan.add(Actions.SWAP_EXACT_OUT, abi.encode(params));
        bytes memory data = plan.finalizeSwap(key0.currency0, key0.currency1, ActionConstants.MSG_SENDER);

        vm.expectRevert(abi.encodeWithSelector(IV4Router.V4TooMuchRequestedPerHop.selector, 0, minPrice, expectedPrice));
        router.executeActions(data);
    }

    function test_swapExactOut_succeedsForAmountInPerHop() public {
        uint256 amountOut = 1 ether;
        uint256 expectedAmountIn = 1008049273448486163;

        uint256 expectedPrice = amountOut * 1e36 / expectedAmountIn;
        uint256[] memory maxSlippages = new uint256[](1);
        uint256 maxSlippage = expectedPrice;
        maxSlippages[0] = maxSlippage;

        tokenPath.push(currency0);
        tokenPath.push(currency1);
        IV4Router.ExactOutputParams memory params = _getExactOutputParams(tokenPath, maxSlippages, amountOut);
        params.amountInMaximum = type(uint128).max;

        plan = plan.add(Actions.SWAP_EXACT_OUT, abi.encode(params));
        bytes memory data = plan.finalizeSwap(key0.currency0, key0.currency1, ActionConstants.MSG_SENDER);

        router.executeActions(data);
    }

    function test_swapExactOut_1Hop_zeroForOne() public {
        uint256 amountOut = 1 ether;
        uint256 expectedAmountIn = 1008049273448486163;

        tokenPath.push(currency0);
        tokenPath.push(currency1);
        IV4Router.ExactOutputParams memory params = _getExactOutputParams(tokenPath, amountOut);

        plan = plan.add(Actions.SWAP_EXACT_OUT, abi.encode(params));

        (
            uint256 inputBalanceBefore,
            uint256 outputBalanceBefore,
            uint256 inputBalanceAfter,
            uint256 outputBalanceAfter
        ) = _finalizeAndExecuteSwap(key0.currency0, key0.currency1, expectedAmountIn);

        assertEq(currency0.balanceOf(address(router)), 0);
        assertEq(currency1.balanceOf(address(router)), 0);

        assertEq(inputBalanceBefore - inputBalanceAfter, expectedAmountIn);
        assertEq(outputBalanceAfter - outputBalanceBefore, amountOut);
    }

    function test_swapExactOut_1Hop_oneForZero() public {
        uint256 amountOut = 1 ether;
        uint256 expectedAmountIn = 1008049273448486163;

        tokenPath.push(currency1);
        tokenPath.push(currency0);
        IV4Router.ExactOutputParams memory params = _getExactOutputParams(tokenPath, amountOut);

        plan = plan.add(Actions.SWAP_EXACT_OUT, abi.encode(params));

        (
            uint256 inputBalanceBefore,
            uint256 outputBalanceBefore,
            uint256 inputBalanceAfter,
            uint256 outputBalanceAfter
        ) = _finalizeAndExecuteSwap(currency1, currency0, expectedAmountIn);

        assertEq(currency0.balanceOf(address(router)), 0);
        assertEq(currency1.balanceOf(address(router)), 0);

        assertEq(inputBalanceBefore - inputBalanceAfter, expectedAmountIn);
        assertEq(outputBalanceAfter - outputBalanceBefore, amountOut);
    }

    function test_swapExactOut_2Hops() public {
        uint256 amountOut = 1 ether;
        uint256 expectedAmountIn = 1016204441757464409;

        tokenPath.push(currency0);
        tokenPath.push(currency1);
        tokenPath.push(currency2);
        IV4Router.ExactOutputParams memory params = _getExactOutputParams(tokenPath, amountOut);

        uint256 intermediateBalanceBefore = currency1.balanceOfSelf();

        plan = plan.add(Actions.SWAP_EXACT_OUT, abi.encode(params));

        (
            uint256 inputBalanceBefore,
            uint256 outputBalanceBefore,
            uint256 inputBalanceAfter,
            uint256 outputBalanceAfter
        ) = _finalizeAndExecuteSwap(currency0, currency2, expectedAmountIn);

        assertEq(intermediateBalanceBefore, currency1.balanceOfSelf());
        assertEq(currency0.balanceOf(address(router)), 0);
        assertEq(currency1.balanceOf(address(router)), 0);
        assertEq(currency2.balanceOf(address(router)), 0);

        assertEq(inputBalanceBefore - inputBalanceAfter, expectedAmountIn);
        assertEq(outputBalanceAfter - outputBalanceBefore, amountOut);
    }

    function test_swapExactOut_3Hops() public {
        uint256 amountOut = 1 ether;
        uint256 expectedAmountIn = 1024467570922834110;

        tokenPath.push(currency0);
        tokenPath.push(currency1);
        tokenPath.push(currency2);
        tokenPath.push(currency3);
        IV4Router.ExactOutputParams memory params = _getExactOutputParams(tokenPath, amountOut);

        plan = plan.add(Actions.SWAP_EXACT_OUT, abi.encode(params));

        (
            uint256 inputBalanceBefore,
            uint256 outputBalanceBefore,
            uint256 inputBalanceAfter,
            uint256 outputBalanceAfter
        ) = _finalizeAndExecuteSwap(currency0, currency3, expectedAmountIn);

        assertEq(currency0.balanceOf(address(router)), 0);
        assertEq(currency1.balanceOf(address(router)), 0);
        assertEq(currency2.balanceOf(address(router)), 0);
        assertEq(currency3.balanceOf(address(router)), 0);

        assertEq(inputBalanceBefore - inputBalanceAfter, expectedAmountIn);
        assertEq(outputBalanceAfter - outputBalanceBefore, amountOut);
    }

    function test_swapExactOut_swapOpenDelta() public {
        uint256 expectedAmountIn = 1008049273448486163;

        tokenPath.push(currency0);
        tokenPath.push(currency1);

        IV4Router.ExactOutputParams memory params = _getExactOutputParams(tokenPath, ActionConstants.OPEN_DELTA);

        plan = plan.add(Actions.TAKE, abi.encode(key0.currency1, ActionConstants.ADDRESS_THIS, 1 ether));
        plan = plan.add(Actions.SWAP_EXACT_OUT, abi.encode(params));
        plan = plan.add(Actions.SETTLE, abi.encode(key0.currency0, ActionConstants.OPEN_DELTA, true));

        bytes memory data = plan.encode();

        uint256 callerInputBefore = key0.currency0.balanceOfSelf();
        uint256 routerInputBefore = key0.currency1.balanceOfSelf();
        uint256 callerOutputBefore = key0.currency1.balanceOfSelf();

        router.executeActions(data);

        uint256 callerInputAfter = key0.currency0.balanceOfSelf();
        uint256 routerInputAfter = key0.currency1.balanceOfSelf();
        uint256 callerOutputAfter = key0.currency1.balanceOfSelf();

        // caller paid
        assertEq(callerInputBefore - expectedAmountIn, callerInputAfter);
        assertEq(routerInputBefore, routerInputAfter);
        assertEq(callerOutputBefore, callerOutputAfter);
    }

    /*//////////////////////////////////////////////////////////////
                ETH -> ERC20 and ERC20 -> ETH EXACT OUTPUT
    //////////////////////////////////////////////////////////////*/

    function test_nativeIn_swapExactOutputSingle_sweepExcessETH() public {
        uint256 amountOut = 1 ether;
        uint256 expectedAmountIn = 1008049273448486163;

        IV4Router.ExactOutputSingleParams memory params = IV4Router.ExactOutputSingleParams(
            nativeKey, true, uint128(amountOut), uint128(expectedAmountIn + 1), 0, bytes("")
        );

        plan = plan.add(Actions.SWAP_EXACT_OUT_SINGLE, abi.encode(params));

        (
            uint256 inputBalanceBefore,
            uint256 outputBalanceBefore,
            uint256 inputBalanceAfter,
            uint256 outputBalanceAfter
        ) = _finalizeAndExecuteNativeInputExactOutputSwap(nativeKey.currency0, nativeKey.currency1, expectedAmountIn);

        assertEq(nativeKey.currency0.balanceOf(address(router)), 0);
        assertEq(nativeKey.currency1.balanceOf(address(router)), 0);

        assertEq(inputBalanceBefore - inputBalanceAfter, expectedAmountIn);
        assertEq(outputBalanceAfter - outputBalanceBefore, amountOut);
    }

    function test_nativeOut_swapExactOutputSingle() public {
        uint256 amountOut = 1 ether;
        uint256 expectedAmountIn = 1008049273448486163;

        IV4Router.ExactOutputSingleParams memory params = IV4Router.ExactOutputSingleParams(
            nativeKey, false, uint128(amountOut), uint128(expectedAmountIn + 1), 0, bytes("")
        );

        plan = plan.add(Actions.SWAP_EXACT_OUT_SINGLE, abi.encode(params));

        (
            uint256 inputBalanceBefore,
            uint256 outputBalanceBefore,
            uint256 inputBalanceAfter,
            uint256 outputBalanceAfter
        ) = _finalizeAndExecuteSwap(nativeKey.currency1, nativeKey.currency0, expectedAmountIn);

        assertEq(nativeKey.currency0.balanceOf(address(router)), 0);
        assertEq(nativeKey.currency1.balanceOf(address(router)), 0);

        assertEq(inputBalanceBefore - inputBalanceAfter, expectedAmountIn);
        assertEq(outputBalanceAfter - outputBalanceBefore, amountOut);
    }

    function test_nativeIn_swapExactOut_1Hop_sweepExcessETH() public {
        uint256 amountOut = 1 ether;
        uint256 expectedAmountIn = 1008049273448486163;

        tokenPath.push(CurrencyLibrary.ADDRESS_ZERO);
        tokenPath.push(nativeKey.currency1);
        IV4Router.ExactOutputParams memory params = _getExactOutputParams(tokenPath, amountOut);

        plan = plan.add(Actions.SWAP_EXACT_OUT, abi.encode(params));

        (
            uint256 inputBalanceBefore,
            uint256 outputBalanceBefore,
            uint256 inputBalanceAfter,
            uint256 outputBalanceAfter
        ) = _finalizeAndExecuteNativeInputExactOutputSwap(
            CurrencyLibrary.ADDRESS_ZERO, nativeKey.currency1, expectedAmountIn
        );

        assertEq(nativeKey.currency0.balanceOf(address(router)), 0);
        assertEq(nativeKey.currency1.balanceOf(address(router)), 0);

        assertEq(inputBalanceBefore - inputBalanceAfter, expectedAmountIn);
        assertEq(outputBalanceAfter - outputBalanceBefore, amountOut);
    }

    function test_nativeOut_swapExactOut_1Hop() public {
        uint256 amountOut = 1 ether;
        uint256 expectedAmountIn = 1008049273448486163;

        tokenPath.push(nativeKey.currency1);
        tokenPath.push(CurrencyLibrary.ADDRESS_ZERO);
        IV4Router.ExactOutputParams memory params = _getExactOutputParams(tokenPath, amountOut);

        plan = plan.add(Actions.SWAP_EXACT_OUT, abi.encode(params));

        (
            uint256 inputBalanceBefore,
            uint256 outputBalanceBefore,
            uint256 inputBalanceAfter,
            uint256 outputBalanceAfter
        ) = _finalizeAndExecuteSwap(nativeKey.currency1, CurrencyLibrary.ADDRESS_ZERO, expectedAmountIn);

        assertEq(nativeKey.currency0.balanceOf(address(router)), 0);
        assertEq(nativeKey.currency1.balanceOf(address(router)), 0);

        assertEq(inputBalanceBefore - inputBalanceAfter, expectedAmountIn);
        assertEq(outputBalanceAfter - outputBalanceBefore, amountOut);
    }

    function test_nativeIn_swapExactOut_2Hops_sweepExcessETH() public {
        uint256 amountOut = 1 ether;
        uint256 expectedAmountIn = 1016204441757464409;

        // the initialized nativeKey is (native, currency0)
        tokenPath.push(CurrencyLibrary.ADDRESS_ZERO);
        tokenPath.push(currency0);
        tokenPath.push(currency1);
        IV4Router.ExactOutputParams memory params = _getExactOutputParams(tokenPath, amountOut);

        uint256 intermediateBalanceBefore = currency0.balanceOfSelf();

        plan = plan.add(Actions.SWAP_EXACT_OUT, abi.encode(params));

        (
            uint256 inputBalanceBefore,
            uint256 outputBalanceBefore,
            uint256 inputBalanceAfter,
            uint256 outputBalanceAfter
        ) = _finalizeAndExecuteNativeInputExactOutputSwap(CurrencyLibrary.ADDRESS_ZERO, currency1, expectedAmountIn);

        assertEq(intermediateBalanceBefore, currency0.balanceOfSelf());
        assertEq(currency1.balanceOf(address(router)), 0);
        assertEq(currency0.balanceOf(address(router)), 0);
        assertEq(CurrencyLibrary.ADDRESS_ZERO.balanceOf(address(router)), 0);

        assertEq(inputBalanceBefore - inputBalanceAfter, expectedAmountIn);
        assertEq(outputBalanceAfter - outputBalanceBefore, amountOut);
    }
}
