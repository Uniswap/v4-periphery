// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {IV4Router} from "../../../src/interfaces/IV4Router.sol";
import {PermissionedRoutingTestHelpers} from "./shared/PermissionedRoutingTestHelpers.sol";
import {Planner} from "../../shared/Planner.sol";
import {Actions} from "../../../src/libraries/Actions.sol";
import {ActionConstants} from "../../../src/libraries/ActionConstants.sol";
import {MockAllowList} from "../../mocks/MockAllowList.sol";
import {IAllowlistChecker} from "../../../src/hooks/permissionedPools/interfaces/IAllowlistChecker.sol";
import {WrappedPermissionedToken} from "../../../src/hooks/permissionedPools/WrappedPermissionedToken.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {console2} from "forge-std/console2.sol";

contract PermissionedV4RouterTest is PermissionedRoutingTestHelpers {
    address public alice = makeAddr("ALICE");
    Currency wrappedCurrency0;
    Currency wrappedCurrency1;

    function setUp() public {
        setupPermissionedRouterCurrenciesAndPoolsWithLiquidity(alice);
        wrappedCurrency0 = Currency.wrap(address(wrappedToken0));
        wrappedCurrency1 = Currency.wrap(address(wrappedToken1));
        plan = Planner.init();
        // Setup permissions and approvals
        setupPermissionsAndApprovals();
    }

    function setupPermissionsAndApprovals() internal {
        // Add addresses to allowlist
        mockAllowList.addToAllowList(alice);

        // Setup approvals for test contract
        _setupApprovals();

        // Setup approvals for authorized user
        vm.startPrank(alice);
        _setupApprovals();
        vm.stopPrank();
    }

    function _setupApprovals() internal {
        IERC20(Currency.unwrap(currency0)).approve(address(permit2), type(uint160).max);
        IERC20(Currency.unwrap(currency1)).approve(address(permit2), type(uint160).max);
        IERC20(Currency.unwrap(currency0)).approve(address(permissionedRouter), type(uint160).max);
        IERC20(Currency.unwrap(currency1)).approve(address(permissionedRouter), type(uint160).max);
        IERC20(Currency.unwrap(currency0)).approve(address(positionManager), type(uint160).max);
        IERC20(Currency.unwrap(currency1)).approve(address(positionManager), type(uint160).max);

        permit2.approve(Currency.unwrap(currency0), address(permissionedRouter), type(uint160).max, 2 ** 47);
        permit2.approve(Currency.unwrap(currency1), address(permissionedRouter), type(uint160).max, 2 ** 47);
        permit2.approve(Currency.unwrap(currency0), address(positionManager), type(uint160).max, 2 ** 47);
        permit2.approve(Currency.unwrap(currency1), address(positionManager), type(uint160).max, 2 ** 47);
    }

    function getInputAndOutputBalances(PoolKey memory poolKey, bool zeroForOne, address manager)
        public
        view
        returns (uint256 inputBalance, uint256 outputBalance, uint256 ethBalance)
    {
        if (zeroForOne) {
            inputBalance = poolKey.currency0.balanceOf(manager);
            outputBalance = poolKey.currency1.balanceOf(manager);
        } else {
            inputBalance = poolKey.currency1.balanceOf(manager);
            outputBalance = poolKey.currency0.balanceOf(manager);
        }
        ethBalance = address(this).balance;
    }

    function getInputAndOutputBalancesPath(Currency[] memory path, address manager)
        public
        view
        returns (uint256 inputBalance, uint256 outputBalance, uint256 ethBalance)
    {
        inputBalance = path[0].balanceOf(manager);
        outputBalance = path[path.length - 1].balanceOf(manager);
        ethBalance = address(this).balance;
    }

    function getPermissionedCurrency(Currency currency) public view returns (Currency) {
        Currency permissionedCurrency = wrappedToPermissioned[currency];
        if (permissionedCurrency == Currency.wrap(address(0))) {
            return currency;
        }
        return permissionedCurrency;
    }

    function test_gas_swapExactInputSingle_permissionedTokens() public {
        uint256 amountIn = 1000;
        PoolKey memory wrappedKey =
            PoolKey(wrappedCurrency1, wrappedCurrency0, 3000, 60, IHooks(address(permissionedRouter)));

        IV4Router.ExactInputSingleParams memory params =
            IV4Router.ExactInputSingleParams(wrappedKey, true, uint128(amountIn), 0, bytes(""));

        plan = plan.add(Actions.SWAP_EXACT_IN_SINGLE, abi.encode(params));
        bytes memory data = plan.finalizeSwap(wrappedCurrency1, wrappedCurrency0, ActionConstants.MSG_SENDER);

        permissionedRouter.execute(data);
        vm.snapshotGasLastCall("PermissionedV4Router_ExactInputSingle_PermissionedTokens");
    }

    /*//////////////////////////////////////////////////////////////
                        PERMISSION TESTS
    //////////////////////////////////////////////////////////////*/

    function test_swap_reverts_unauthorized_user() public {
        address unauthorizedUser = makeAddr("UNAUTHORIZED");
        IERC20(Currency.unwrap(currency0)).transfer(unauthorizedUser, 2 ether);
        IERC20(Currency.unwrap(currency1)).transfer(unauthorizedUser, 2 ether);
        uint256 amountIn = 1 ether;

        PoolKey memory wrappedKey = PoolKey(currency0, currency1, 3000, 60, IHooks(address(permissionedRouter)));

        IV4Router.ExactInputSingleParams memory params =
            IV4Router.ExactInputSingleParams(wrappedKey, true, uint128(amountIn), 0, bytes(""));

        plan = plan.add(Actions.SWAP_EXACT_IN_SINGLE, abi.encode(params));
        bytes memory data = plan.finalizeSwap(currency0, currency1, ActionConstants.MSG_SENDER);

        vm.prank(unauthorizedUser);
        vm.expectRevert();
        permissionedRouter.execute(data);
    }

    function test_swap_succeeds_authorized_user() public {
        IERC20(Currency.unwrap(currency0)).transfer(alice, 2 ether);
        IERC20(Currency.unwrap(currency1)).transfer(alice, 2 ether);

        uint256 amountIn = 100;

        PoolKey memory wrappedKey =
            PoolKey(wrappedCurrency1, wrappedCurrency0, 3000, 60, IHooks(address(permissionedRouter)));

        IV4Router.ExactInputSingleParams memory params =
            IV4Router.ExactInputSingleParams(wrappedKey, true, uint128(amountIn), 0, bytes(""));

        plan = plan.add(Actions.SWAP_EXACT_IN_SINGLE, abi.encode(params));
        bytes memory data = plan.finalizeSwap(wrappedCurrency1, wrappedCurrency0, ActionConstants.MSG_SENDER);

        vm.prank(alice);
        permissionedRouter.execute(data);
    }

    /*//////////////////////////////////////////////////////////////
                        ERC20 -> ERC20 EXACT INPUT
    //////////////////////////////////////////////////////////////*/

    function test_swapExactInputSingle_revertsForAmountOut() public {
        uint256 amountIn = 1 ether;
        uint256 expectedAmountOut = 19992;
        // min amount out of 1 higher than the actual amount out
        IV4Router.ExactInputSingleParams memory params =
            IV4Router.ExactInputSingleParams(key0, true, uint128(amountIn), uint128(expectedAmountOut + 1), bytes(""));

        plan = plan.add(Actions.SWAP_EXACT_IN_SINGLE, abi.encode(params));
        bytes memory data = plan.finalizeSwap(key0.currency0, key0.currency1, ActionConstants.MSG_SENDER);

        vm.expectRevert(
            abi.encodeWithSelector(IV4Router.V4TooLittleReceived.selector, expectedAmountOut + 1, expectedAmountOut)
        );
        permissionedRouter.execute(data);
    }

    function test_swapExactInputSingle_zeroForOne_takeToMsgSender() public {
        uint256 amountIn = 1 ether;
        uint256 expectedAmountOut = 19992;

        IV4Router.ExactInputSingleParams memory params =
            IV4Router.ExactInputSingleParams(key0, true, uint128(amountIn), 0, bytes(""));

        plan = plan.add(Actions.SWAP_EXACT_IN_SINGLE, abi.encode(params));
        (uint256 inputBalanceBefore, uint256 outputBalanceBefore,) =
            getInputAndOutputBalances(key0, true, address(manager));
        _finalizeAndExecuteSwap(key0.currency0, key0.currency1, amountIn);
        (uint256 inputBalanceAfter, uint256 outputBalanceAfter,) =
            getInputAndOutputBalances(key0, true, address(manager));

        assertEq(inputBalanceAfter - inputBalanceBefore, amountIn);
        assertEq(outputBalanceBefore - outputBalanceAfter, expectedAmountOut);
    }

    function test_swapExactInputSingle_zeroForOne_takeToRecipient() public {
        uint256 amountIn = 1 ether;
        uint256 expectedAmountOut = 19992;

        (uint256 inputBalanceBefore, uint256 outputBalanceBefore,) =
            getInputAndOutputBalances(key0, true, address(manager));

        IV4Router.ExactInputSingleParams memory params =
            IV4Router.ExactInputSingleParams(key0, true, uint128(amountIn), 0, bytes(""));

        plan = plan.add(Actions.SWAP_EXACT_IN_SINGLE, abi.encode(params));

        uint256 aliceOutputBalanceBefore = getPermissionedCurrency(key0.currency1).balanceOf(alice);
        // swap with alice as the take recipient
        _finalizeAndExecuteSwap(key0.currency0, key0.currency1, amountIn, alice);
        (uint256 inputBalanceAfter, uint256 outputBalanceAfter,) =
            getInputAndOutputBalances(key0, true, address(manager));

        uint256 aliceOutputBalanceAfter = getPermissionedCurrency(key0.currency1).balanceOf(alice);

        assertEq(inputBalanceAfter - inputBalanceBefore, amountIn);
        assertEq(outputBalanceBefore - outputBalanceAfter, expectedAmountOut);
        assertEq(aliceOutputBalanceAfter - aliceOutputBalanceBefore, expectedAmountOut);
    }

    // This is not a real use-case in isolation, but will be used in the UniversalRouter if a v4
    // swap is before another swap on v2/v3
    function test_swapExactInputSingle_zeroForOne_takeAllToRouter() public {
        uint256 amountIn = 1 ether;
        uint256 expectedAmountOut = 19992;

        IV4Router.ExactInputSingleParams memory params =
            IV4Router.ExactInputSingleParams(key0, true, uint128(amountIn), 0, bytes(""));

        plan = plan.add(Actions.SWAP_EXACT_IN_SINGLE, abi.encode(params));

        // the router holds no funds before
        assertEq(wrappedCurrency0.balanceOf(address(permissionedRouter)), 0);
        assertEq(wrappedCurrency1.balanceOf(address(permissionedRouter)), 0);
        (uint256 inputBalanceBefore, uint256 outputBalanceBefore,) =
            getInputAndOutputBalances(key0, true, address(manager));
        // swap with the router as the take recipient
        _finalizeAndExecuteSwap(key0.currency0, key0.currency1, amountIn, ActionConstants.ADDRESS_THIS);
        (uint256 inputBalanceAfter, uint256 outputBalanceAfter,) =
            getInputAndOutputBalances(key0, true, address(manager));

        assertEq(inputBalanceAfter - inputBalanceBefore, amountIn);
        assertEq(outputBalanceBefore - outputBalanceAfter, expectedAmountOut);
    }

    // This is not a real use-case in isolation, but will be used in the UniversalRouter if a v4
    // swap is before another swap on v2/v3
    function test_swapExactInputSingle_zeroForOne_takeToRouter() public {
        uint256 amountIn = 1000;
        uint256 expectedAmountOut = 949;

        Currency inputCurrency = getPermissionedCurrency(key0.currency0);
        Currency outputCurrency = getPermissionedCurrency(key0.currency1);
        IV4Router.ExactInputSingleParams memory params =
            IV4Router.ExactInputSingleParams(key0, true, uint128(amountIn), 0, bytes(""));

        plan = plan.add(Actions.SWAP_EXACT_IN_SINGLE, abi.encode(params));
        plan = plan.add(Actions.SETTLE_ALL, abi.encode(key0.currency0, expectedAmountOut * 12 / 10));
        // take the entire open delta to the router's address
        plan =
            plan.add(Actions.TAKE, abi.encode(key0.currency1, ActionConstants.ADDRESS_THIS, ActionConstants.OPEN_DELTA));
        bytes memory data = plan.encode();
        // the router holds no funds before
        assertEq(inputCurrency.balanceOf(address(permissionedRouter)), 0);
        assertEq(outputCurrency.balanceOf(address(permissionedRouter)), 0);
        permissionedRouter.execute(data);
        // the output tokens have been left in the router
        assertEq(outputCurrency.balanceOf(address(permissionedRouter)), expectedAmountOut);
        assertEq(inputCurrency.balanceOf(address(permissionedRouter)), 0);
    }

    function test_swapExactInputSingle_oneForZero() public {
        uint256 amountIn = 1 ether;
        uint256 expectedAmountOut = 19992;
        bool zeroForOne = false;
        IV4Router.ExactInputSingleParams memory params =
            IV4Router.ExactInputSingleParams(key0, zeroForOne, uint128(amountIn), 0, bytes(""));
        plan = plan.add(Actions.SWAP_EXACT_IN_SINGLE, abi.encode(params));
        (uint256 inputBalanceBefore, uint256 outputBalanceBefore,) =
            getInputAndOutputBalances(key0, zeroForOne, address(manager));
        _finalizeAndExecuteSwap(key0.currency1, key0.currency0, amountIn);
        (uint256 inputBalanceAfter, uint256 outputBalanceAfter,) =
            getInputAndOutputBalances(key0, zeroForOne, address(manager));

        assertEq(key0.currency0.balanceOf(address(permissionedRouter)), 0);
        assertEq(key0.currency1.balanceOf(address(permissionedRouter)), 0);

        assertEq(inputBalanceAfter - inputBalanceBefore, amountIn);
        assertEq(outputBalanceBefore - outputBalanceAfter, expectedAmountOut);
    }

    function test_swapExactInput_revertsForAmountOut() public {
        uint256 amountIn = 1000;
        uint256 expectedAmountOut = 949;

        tokenPath.push(wrappedCurrency0);
        tokenPath.push(wrappedCurrency1);
        IV4Router.ExactInputParams memory params =
            _getExactInputParamsWithHook(tokenPath, amountIn, address(permissionedRouter));
        params.amountOutMinimum = uint128(expectedAmountOut + 1);

        plan = plan.add(Actions.SWAP_EXACT_IN, abi.encode(params));
        bytes memory data = plan.finalizeSwap(key0.currency0, key0.currency1, ActionConstants.MSG_SENDER);

        vm.expectRevert(
            abi.encodeWithSelector(IV4Router.V4TooLittleReceived.selector, expectedAmountOut + 1, expectedAmountOut)
        );
        permissionedRouter.execute(data);
    }

    function test_swapExactIn_1Hop_zeroForOne() public {
        uint256 amountIn = 1 ether;
        uint256 expectedAmountOut = 19992;

        tokenPath.push(wrappedCurrency0);
        tokenPath.push(wrappedCurrency1);
        IV4Router.ExactInputParams memory params =
            _getExactInputParamsWithHook(tokenPath, amountIn, address(permissionedRouter));
        plan = plan.add(Actions.SWAP_EXACT_IN, abi.encode(params));
        (uint256 inputBalanceBefore, uint256 outputBalanceBefore,) =
            getInputAndOutputBalancesPath(tokenPath, address(manager));
        _finalizeAndExecuteSwap(wrappedCurrency0, wrappedCurrency1, amountIn);
        (uint256 inputBalanceAfter, uint256 outputBalanceAfter,) =
            getInputAndOutputBalancesPath(tokenPath, address(manager));

        assertEq(wrappedCurrency0.balanceOf(address(permissionedRouter)), 0);
        assertEq(wrappedCurrency1.balanceOf(address(permissionedRouter)), 0);

        assertEq(inputBalanceAfter - inputBalanceBefore, amountIn);
        assertEq(outputBalanceBefore - outputBalanceAfter, expectedAmountOut);
    }

    function test_swapExactIn_1Hop_oneForZero() public {
        uint256 amountIn = 1 ether;
        uint256 expectedAmountOut = 19992;

        tokenPath.push(wrappedCurrency1);
        tokenPath.push(wrappedCurrency0);
        IV4Router.ExactInputParams memory params =
            _getExactInputParamsWithHook(tokenPath, amountIn, address(permissionedRouter));

        plan = plan.add(Actions.SWAP_EXACT_IN, abi.encode(params));

        (uint256 inputBalanceBefore, uint256 outputBalanceBefore,) =
            getInputAndOutputBalancesPath(tokenPath, address(manager));
        _finalizeAndExecuteSwap(wrappedCurrency1, wrappedCurrency0, amountIn);
        (uint256 inputBalanceAfter, uint256 outputBalanceAfter,) =
            getInputAndOutputBalancesPath(tokenPath, address(manager));

        assertEq(wrappedCurrency0.balanceOf(address(permissionedRouter)), 0);
        assertEq(wrappedCurrency1.balanceOf(address(permissionedRouter)), 0);

        assertEq(inputBalanceAfter - inputBalanceBefore, amountIn);
        assertEq(outputBalanceBefore - outputBalanceAfter, expectedAmountOut);
    }

    function test_swapExactIn_2Hops() public {
        uint256 amountIn = 1 ether;
        uint256 expectedAmountOut = 9982;

        tokenPath.push(wrappedCurrency0);
        tokenPath.push(wrappedCurrency1);
        tokenPath.push(currency2);
        IV4Router.ExactInputParams memory params =
            _getExactInputParamsWithHook(tokenPath, amountIn, address(permissionedRouter));

        plan = plan.add(Actions.SWAP_EXACT_IN, abi.encode(params));

        uint256 intermediateBalanceBefore = currency1.balanceOfSelf();

        (uint256 inputBalanceBefore, uint256 outputBalanceBefore,) =
            getInputAndOutputBalancesPath(tokenPath, address(manager));
        _finalizeAndExecuteSwap(wrappedCurrency0, currency2, amountIn);
        (uint256 inputBalanceAfter, uint256 outputBalanceAfter,) =
            getInputAndOutputBalancesPath(tokenPath, address(manager));

        // check intermediate token balances
        assertEq(intermediateBalanceBefore, currency1.balanceOfSelf());
        assertEq(wrappedCurrency0.balanceOf(address(permissionedRouter)), 0);
        assertEq(wrappedCurrency1.balanceOf(address(permissionedRouter)), 0);
        assertEq(currency2.balanceOf(address(permissionedRouter)), 0);
        assertEq(inputBalanceAfter - inputBalanceBefore, amountIn);
        assertEq(outputBalanceBefore - outputBalanceAfter, expectedAmountOut);
    }

    function test_swapExactIn_3Hops() public {
        uint256 amountIn = 1 ether;
        uint256 expectedAmountOut = 6645;

        tokenPath.push(wrappedCurrency0);
        tokenPath.push(wrappedCurrency1);
        tokenPath.push(currency2);
        tokenPath.push(currency3);
        IV4Router.ExactInputParams memory params =
            _getExactInputParamsWithHook(tokenPath, amountIn, address(permissionedRouter));

        plan = plan.add(Actions.SWAP_EXACT_IN, abi.encode(params));

        (uint256 inputBalanceBefore, uint256 outputBalanceBefore,) =
            getInputAndOutputBalancesPath(tokenPath, address(manager));
        _finalizeAndExecuteSwap(wrappedCurrency0, currency3, amountIn);
        (uint256 inputBalanceAfter, uint256 outputBalanceAfter,) =
            getInputAndOutputBalancesPath(tokenPath, address(manager));

        // check intermediate tokens werent left in the router
        assertEq(wrappedCurrency0.balanceOf(address(permissionedRouter)), 0);
        assertEq(wrappedCurrency1.balanceOf(address(permissionedRouter)), 0);
        assertEq(currency2.balanceOf(address(permissionedRouter)), 0);
        assertEq(currency3.balanceOf(address(permissionedRouter)), 0);
        assertEq(inputBalanceAfter - inputBalanceBefore, amountIn);
        assertEq(outputBalanceBefore - outputBalanceAfter, expectedAmountOut);
    }

    /*//////////////////////////////////////////////////////////////
                ETH -> ERC20 and ERC20 -> ETH EXACT INPUT
    //////////////////////////////////////////////////////////////*/

    function test_nativeIn_swapExactInputSingle() public {
        uint256 amountIn = 1 ether;
        uint256 expectedAmountOut = 19992;

        IV4Router.ExactInputSingleParams memory params =
            IV4Router.ExactInputSingleParams(nativeKey, true, uint128(amountIn), 0, bytes(""));

        plan = plan.add(Actions.SWAP_EXACT_IN_SINGLE, abi.encode(params));

        (, uint256 outputBalanceBefore, uint256 ethBalanceBefore) =
            getInputAndOutputBalances(nativeKey, true, address(manager));
        _finalizeAndExecuteSwap(nativeKey.currency0, nativeKey.currency1, amountIn);
        (, uint256 outputBalanceAfter, uint256 ethBalanceAfter) =
            getInputAndOutputBalances(nativeKey, true, address(manager));

        assertEq(nativeKey.currency0.balanceOf(address(permissionedRouter)), 0);
        assertEq(nativeKey.currency1.balanceOf(address(permissionedRouter)), 0);
        assertEq(ethBalanceBefore - ethBalanceAfter, amountIn);
        assertEq(outputBalanceBefore - outputBalanceAfter, expectedAmountOut);
    }

    function test_nativeOut_swapExactInputSingle() public {
        uint256 amountIn = 1 ether;
        uint256 expectedAmountOut = 19992;
        bool zeroForOne = false;
        // native output means we need !zeroForOne
        IV4Router.ExactInputSingleParams memory params =
            IV4Router.ExactInputSingleParams(nativeKey, zeroForOne, uint128(amountIn), 0, bytes(""));

        plan = plan.add(Actions.SWAP_EXACT_IN_SINGLE, abi.encode(params));

        (uint256 inputBalanceBefore,, uint256 ethBalanceBefore) =
            getInputAndOutputBalances(nativeKey, zeroForOne, address(manager));
        _finalizeAndExecuteSwap(nativeKey.currency1, nativeKey.currency0, amountIn);
        (uint256 inputBalanceAfter,, uint256 ethBalanceAfter) =
            getInputAndOutputBalances(nativeKey, zeroForOne, address(manager));

        assertEq(nativeKey.currency0.balanceOf(address(permissionedRouter)), 0);
        assertEq(nativeKey.currency1.balanceOf(address(permissionedRouter)), 0);
        assertEq(ethBalanceAfter - ethBalanceBefore, expectedAmountOut);
        assertEq(inputBalanceAfter - inputBalanceBefore, amountIn);
    }

    function test_nativeIn_swapExactIn_1Hop() public {
        uint256 amountIn = 1 ether;
        uint256 expectedAmountOut = 19992;

        tokenPath.push(CurrencyLibrary.ADDRESS_ZERO);
        tokenPath.push(nativeKey.currency1);
        IV4Router.ExactInputParams memory params =
            _getExactInputParamsWithHook(tokenPath, amountIn, address(permissionedRouter));
        plan = plan.add(Actions.SWAP_EXACT_IN, abi.encode(params));

        (, uint256 outputBalanceBefore, uint256 ethBalanceBefore) =
            getInputAndOutputBalancesPath(tokenPath, address(manager));
        _finalizeAndExecuteSwap(CurrencyLibrary.ADDRESS_ZERO, nativeKey.currency1, amountIn);
        (, uint256 outputBalanceAfter, uint256 ethBalanceAfter) =
            getInputAndOutputBalancesPath(tokenPath, address(manager));

        assertEq(nativeKey.currency0.balanceOf(address(permissionedRouter)), 0);
        assertEq(nativeKey.currency1.balanceOf(address(permissionedRouter)), 0);
        assertEq(ethBalanceBefore - ethBalanceAfter, amountIn);
        assertEq(outputBalanceBefore - outputBalanceAfter, expectedAmountOut);
    }

    function test_nativeOut_swapExactIn_1Hop() public {
        uint256 amountIn = 1 ether;
        uint256 expectedAmountOut = 19992;

        tokenPath.push(nativeKey.currency1);
        tokenPath.push(CurrencyLibrary.ADDRESS_ZERO);
        IV4Router.ExactInputParams memory params =
            _getExactInputParamsWithHook(tokenPath, amountIn, address(permissionedRouter));

        plan = plan.add(Actions.SWAP_EXACT_IN, abi.encode(params));

        (uint256 inputBalanceBefore,, uint256 ethBalanceBefore) =
            getInputAndOutputBalancesPath(tokenPath, address(manager));
        _finalizeAndExecuteSwap(nativeKey.currency1, CurrencyLibrary.ADDRESS_ZERO, amountIn);
        (uint256 inputBalanceAfter,, uint256 ethBalanceAfter) =
            getInputAndOutputBalancesPath(tokenPath, address(manager));

        assertEq(nativeKey.currency0.balanceOf(address(permissionedRouter)), 0);
        assertEq(nativeKey.currency1.balanceOf(address(permissionedRouter)), 0);
        assertEq(inputBalanceAfter - inputBalanceBefore, amountIn);
        assertEq(ethBalanceAfter - ethBalanceBefore, expectedAmountOut);
    }

    function test_nativeIn_swapExactIn_2Hops() public {
        uint256 amountIn = 1 ether;
        uint256 expectedAmountOut = 9982;

        // the initialized nativeKey is (native, currency0)
        tokenPath.push(CurrencyLibrary.ADDRESS_ZERO);
        tokenPath.push(wrappedCurrency0);
        tokenPath.push(wrappedCurrency1);
        IV4Router.ExactInputParams memory params =
            _getExactInputParamsWithHook(tokenPath, amountIn, address(permissionedRouter));

        plan = plan.add(Actions.SWAP_EXACT_IN, abi.encode(params));

        uint256 intermediateBalanceBefore = currency0.balanceOfSelf();
        (, uint256 outputBalanceBefore, uint256 ethBalanceBefore) =
            getInputAndOutputBalancesPath(tokenPath, address(manager));
        _finalizeAndExecuteSwap(CurrencyLibrary.ADDRESS_ZERO, wrappedCurrency1, amountIn);
        (, uint256 outputBalanceAfter, uint256 ethBalanceAfter) =
            getInputAndOutputBalancesPath(tokenPath, address(manager));

        // check intermediate token balances
        assertEq(intermediateBalanceBefore, currency0.balanceOfSelf());

        assertEq(nativeKey.currency0.balanceOf(address(permissionedRouter)), 0);
        assertEq(nativeKey.currency1.balanceOf(address(permissionedRouter)), 0);
        assertEq(wrappedCurrency1.balanceOf(address(permissionedRouter)), 0);
        assertEq(ethBalanceBefore - ethBalanceAfter, amountIn);
        assertEq(outputBalanceBefore - outputBalanceAfter, expectedAmountOut);
    }

    function test_nativeOut_swapExactIn_2Hops() public {
        uint256 amountIn = 1 ether;
        uint256 expectedAmountOut = 9982;

        // the initialized nativeKey is (native, currency0)
        tokenPath.push(wrappedCurrency1);
        tokenPath.push(wrappedCurrency0);
        tokenPath.push(CurrencyLibrary.ADDRESS_ZERO);
        IV4Router.ExactInputParams memory params =
            _getExactInputParamsWithHook(tokenPath, amountIn, address(permissionedRouter));

        plan = plan.add(Actions.SWAP_EXACT_IN, abi.encode(params));

        uint256 intermediateBalanceBefore = currency0.balanceOfSelf();

        (uint256 inputBalanceBefore,, uint256 ethBalanceBefore) =
            getInputAndOutputBalancesPath(tokenPath, address(manager));
        _finalizeAndExecuteSwap(wrappedCurrency1, CurrencyLibrary.ADDRESS_ZERO, amountIn);
        (uint256 inputBalanceAfter,, uint256 ethBalanceAfter) =
            getInputAndOutputBalancesPath(tokenPath, address(manager));

        // check intermediate token balances
        assertEq(intermediateBalanceBefore, currency0.balanceOfSelf());
        assertEq(nativeKey.currency0.balanceOf(address(permissionedRouter)), 0);
        assertEq(nativeKey.currency1.balanceOf(address(permissionedRouter)), 0);
        assertEq(currency1.balanceOf(address(permissionedRouter)), 0);
        assertEq(ethBalanceAfter - ethBalanceBefore, expectedAmountOut);
        assertEq(inputBalanceAfter - inputBalanceBefore, amountIn);
    }

    /*//////////////////////////////////////////////////////////////
                        ERC20 -> ERC20 EXACT OUTPUT
    //////////////////////////////////////////////////////////////*/

    function test_swapExactOutputSingle_revertsForAmountIn() public {
        uint256 amountOut = 1 ether;
        uint256 expectedAmountIn = 369070324193623892281288;

        IV4Router.ExactOutputSingleParams memory params =
            IV4Router.ExactOutputSingleParams(key0, true, uint128(amountOut), uint128(expectedAmountIn - 1), bytes(""));

        plan = plan.add(Actions.SWAP_EXACT_OUT_SINGLE, abi.encode(params));
        bytes memory data = plan.finalizeSwap(key0.currency0, key0.currency1, ActionConstants.MSG_SENDER);

        vm.expectRevert(
            abi.encodeWithSelector(
                IV4Router.V4TooMuchRequested.selector, expectedAmountIn - 1, 369070324193623892281288
            )
        );
        permissionedRouter.execute(data);
    }

    function test_swapExactOutputSingle_zeroForOne() public {
        uint256 amountOut = 19992;
        uint256 expectedAmountIn = 434604409;
        bool zeroForOne = true;
        IV4Router.ExactOutputSingleParams memory params = IV4Router.ExactOutputSingleParams(
            key0, zeroForOne, uint128(amountOut), uint128(expectedAmountIn + 1), bytes("")
        );

        plan = plan.add(Actions.SWAP_EXACT_OUT_SINGLE, abi.encode(params));

        (uint256 inputBalanceBefore, uint256 outputBalanceBefore,) =
            getInputAndOutputBalances(key0, zeroForOne, address(manager));
        _finalizeAndExecuteSwap(key0.currency0, key0.currency1, expectedAmountIn);
        (uint256 inputBalanceAfter, uint256 outputBalanceAfter,) =
            getInputAndOutputBalances(key0, zeroForOne, address(manager));

        assertEq(key0.currency0.balanceOf(address(permissionedRouter)), 0);
        assertEq(key0.currency1.balanceOf(address(permissionedRouter)), 0);
        assertEq(currency0.balanceOf(address(permissionedRouter)), 0);
        assertEq(currency1.balanceOf(address(permissionedRouter)), 0);
        assertEq(outputBalanceBefore - outputBalanceAfter, amountOut);
        assertEq(inputBalanceAfter - inputBalanceBefore, expectedAmountIn);
    }

    function test_swapExactOutputSingle_oneForZero() public {
        uint256 amountOut = 19992;
        uint256 expectedAmountIn = 433302557;
        bool zeroForOne = false;
        IV4Router.ExactOutputSingleParams memory params = IV4Router.ExactOutputSingleParams(
            key0, zeroForOne, uint128(amountOut), uint128(expectedAmountIn + 1), bytes("")
        );

        plan = plan.add(Actions.SWAP_EXACT_OUT_SINGLE, abi.encode(params));

        (uint256 inputBalanceBefore, uint256 outputBalanceBefore,) =
            getInputAndOutputBalances(key0, zeroForOne, address(manager));
        _finalizeAndExecuteSwap(key0.currency1, key0.currency0, expectedAmountIn);
        (uint256 inputBalanceAfter, uint256 outputBalanceAfter,) =
            getInputAndOutputBalances(key0, zeroForOne, address(manager));

        assertEq(wrappedCurrency0.balanceOf(address(permissionedRouter)), 0);
        assertEq(wrappedCurrency1.balanceOf(address(permissionedRouter)), 0);

        assertEq(outputBalanceBefore - outputBalanceAfter, amountOut);
        assertEq(inputBalanceAfter - inputBalanceBefore, expectedAmountIn);
    }

    function test_swapExactOut_revertsForAmountIn() public {
        uint256 amountOut = 1 ether;
        uint256 expectedAmountIn = 369070324262815812743748;

        tokenPath.push(wrappedCurrency0);
        tokenPath.push(wrappedCurrency1);
        IV4Router.ExactOutputParams memory params =
            _getExactOutputParamsWithHook(tokenPath, amountOut, address(permissionedRouter));
        params.amountInMaximum = uint128(expectedAmountIn - 1);

        plan = plan.add(Actions.SWAP_EXACT_OUT, abi.encode(params));
        bytes memory data = plan.finalizeSwap(key0.currency0, key0.currency1, ActionConstants.MSG_SENDER);

        vm.expectRevert(
            abi.encodeWithSelector(IV4Router.V4TooMuchRequested.selector, expectedAmountIn - 1, expectedAmountIn)
        );
        permissionedRouter.execute(data);
    }

    function test_swapExactOut_1Hop_zeroForOne() public {
        uint256 amountOut = 19992;
        uint256 expectedAmountIn = 434604409;

        tokenPath.push(wrappedCurrency1);
        tokenPath.push(wrappedCurrency0);
        IV4Router.ExactOutputParams memory params =
            _getExactOutputParamsWithHook(tokenPath, amountOut, address(permissionedRouter));

        plan = plan.add(Actions.SWAP_EXACT_OUT, abi.encode(params));
        (uint256 inputBalanceBefore, uint256 outputBalanceBefore,) =
            getInputAndOutputBalancesPath(tokenPath, address(manager));
        _finalizeAndExecuteSwap(key0.currency0, key0.currency1, expectedAmountIn);
        (uint256 inputBalanceAfter, uint256 outputBalanceAfter,) =
            getInputAndOutputBalancesPath(tokenPath, address(manager));

        assertEq(wrappedCurrency0.balanceOf(address(permissionedRouter)), 0);
        assertEq(wrappedCurrency1.balanceOf(address(permissionedRouter)), 0);

        assertEq(outputBalanceBefore - outputBalanceAfter, amountOut);
        assertEq(inputBalanceAfter - inputBalanceBefore, expectedAmountIn);
    }

    function test_swapExactOut_1Hop_oneForZero() public {
        uint256 amountOut = 19992;
        uint256 expectedAmountIn = 433302557;

        tokenPath.push(wrappedCurrency0);
        tokenPath.push(wrappedCurrency1);
        IV4Router.ExactOutputParams memory params =
            _getExactOutputParamsWithHook(tokenPath, amountOut, address(permissionedRouter));

        plan = plan.add(Actions.SWAP_EXACT_OUT, abi.encode(params));
        (uint256 inputBalanceBefore, uint256 outputBalanceBefore,) =
            getInputAndOutputBalancesPath(tokenPath, address(manager));
        _finalizeAndExecuteSwap(wrappedCurrency0, key0.currency0, expectedAmountIn);
        (uint256 inputBalanceAfter, uint256 outputBalanceAfter,) =
            getInputAndOutputBalancesPath(tokenPath, address(manager));

        assertEq(wrappedCurrency0.balanceOf(address(permissionedRouter)), 0);
        assertEq(wrappedCurrency1.balanceOf(address(permissionedRouter)), 0);
        assertEq(outputBalanceBefore - outputBalanceAfter, amountOut);
        assertEq(inputBalanceAfter - inputBalanceBefore, expectedAmountIn);
    }

    function test_swapExactOut_2Hops() public {
        uint256 amountOut = 19992;
        uint256 expectedAmountIn = 434604409;

        tokenPath.push(wrappedCurrency0);
        tokenPath.push(wrappedCurrency1);
        tokenPath.push(currency2);
        IV4Router.ExactOutputParams memory params =
            _getExactOutputParamsWithHook(tokenPath, amountOut, address(permissionedRouter));

        uint256 intermediateBalanceBefore = currency0.balanceOfSelf();

        plan = plan.add(Actions.SWAP_EXACT_OUT, abi.encode(params));
        (uint256 inputBalanceBefore, uint256 outputBalanceBefore,) =
            getInputAndOutputBalancesPath(tokenPath, address(manager));
        _finalizeAndExecuteSwap(wrappedCurrency0, currency2, expectedAmountIn);
        (uint256 inputBalanceAfter, uint256 outputBalanceAfter,) =
            getInputAndOutputBalancesPath(tokenPath, address(manager));

        assertEq(intermediateBalanceBefore, currency0.balanceOfSelf());
        assertEq(wrappedCurrency0.balanceOf(address(permissionedRouter)), 0);
        assertEq(wrappedCurrency1.balanceOf(address(permissionedRouter)), 0);
        assertEq(currency2.balanceOf(address(permissionedRouter)), 0);
        assertEq(outputBalanceBefore - outputBalanceAfter, amountOut);
        assertEq(inputBalanceAfter - inputBalanceBefore, expectedAmountIn);
    }

    function test_swapExactOut_3Hops() public {
        uint256 amountOut = 100;
        uint256 expectedAmountIn = 10000;

        tokenPath.push(wrappedCurrency0);
        tokenPath.push(wrappedCurrency1);
        tokenPath.push(currency2);
        tokenPath.push(currency3);

        IV4Router.ExactOutputParams memory params =
            _getExactOutputParamsWithHook(tokenPath, amountOut, address(permissionedRouter));

        plan = plan.add(Actions.SWAP_EXACT_OUT, abi.encode(params));

        (uint256 inputBalanceBefore, uint256 outputBalanceBefore,) =
            getInputAndOutputBalancesPath(tokenPath, address(manager));
        _finalizeAndExecuteSwap(key0.currency0, currency3, expectedAmountIn);
        (uint256 inputBalanceAfter, uint256 outputBalanceAfter,) =
            getInputAndOutputBalancesPath(tokenPath, address(manager));

        assertEq(wrappedCurrency0.balanceOf(address(permissionedRouter)), 0);
        assertEq(wrappedCurrency1.balanceOf(address(permissionedRouter)), 0);
        assertEq(currency2.balanceOf(address(permissionedRouter)), 0);
        assertEq(currency3.balanceOf(address(permissionedRouter)), 0);
        assertEq(outputBalanceBefore - outputBalanceAfter, amountOut);
        assertEq(inputBalanceAfter - inputBalanceBefore, expectedAmountIn);
    }

    /*//////////////////////////////////////////////////////////////
                ETH -> ERC20 and ERC20 -> ETH EXACT OUTPUT
    //////////////////////////////////////////////////////////////*/

    function test_nativeOut_swapExactOutputSingle() public {
        uint256 amountOut = 19992;
        uint256 expectedAmountIn = 433302557;
        bool zeroForOne = false;
        IV4Router.ExactOutputSingleParams memory params = IV4Router.ExactOutputSingleParams(
            nativeKey, zeroForOne, uint128(amountOut), uint128(expectedAmountIn + 1), bytes("")
        );

        plan = plan.add(Actions.SWAP_EXACT_OUT_SINGLE, abi.encode(params));

        (uint256 inputBalanceBefore,, uint256 ethBalanceBefore) =
            getInputAndOutputBalances(nativeKey, zeroForOne, address(manager));
        _finalizeAndExecuteSwap(nativeKey.currency1, nativeKey.currency0, expectedAmountIn);
        (uint256 inputBalanceAfter,, uint256 ethBalanceAfter) =
            getInputAndOutputBalances(nativeKey, zeroForOne, address(manager));

        assertEq(nativeKey.currency0.balanceOf(address(permissionedRouter)), 0);
        assertEq(nativeKey.currency1.balanceOf(address(permissionedRouter)), 0);
        assertEq(ethBalanceAfter - ethBalanceBefore, amountOut);
        assertEq(inputBalanceAfter - inputBalanceBefore, expectedAmountIn);
    }

    function test_nativeOut_swapExactOut_1Hop() public {
        uint256 amountOut = 19992;
        uint256 expectedAmountIn = 433302557;

        tokenPath.push(nativeKey.currency1);
        tokenPath.push(CurrencyLibrary.ADDRESS_ZERO);
        IV4Router.ExactOutputParams memory params =
            _getExactOutputParamsWithHook(tokenPath, amountOut, address(permissionedRouter));

        plan = plan.add(Actions.SWAP_EXACT_OUT, abi.encode(params));
        (uint256 inputBalanceBefore,, uint256 ethBalanceBefore) =
            getInputAndOutputBalancesPath(tokenPath, address(manager));
        _finalizeAndExecuteSwap(nativeKey.currency1, CurrencyLibrary.ADDRESS_ZERO, expectedAmountIn);
        (uint256 inputBalanceAfter,, uint256 ethBalanceAfter) =
            getInputAndOutputBalancesPath(tokenPath, address(manager));

        assertEq(nativeKey.currency0.balanceOf(address(permissionedRouter)), 0);
        assertEq(nativeKey.currency1.balanceOf(address(permissionedRouter)), 0);
        assertEq(ethBalanceAfter - ethBalanceBefore, amountOut);
        assertEq(inputBalanceAfter - inputBalanceBefore, expectedAmountIn);
    }
}
