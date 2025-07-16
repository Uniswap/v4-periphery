// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {PermitHash} from "permit2/src/libraries/PermitHash.sol";
import {IV4Router} from "../../../src/interfaces/IV4Router.sol";
import {PermissionedRoutingTestHelpers} from "./shared/PermissionedRoutingTestHelpers.sol";
import {Planner} from "../../shared/Planner.sol";
import {Actions} from "../../../src/libraries/Actions.sol";
import {ActionConstants} from "../../../src/libraries/ActionConstants.sol";
import {MockPermissionedToken} from "./PermissionedPoolsBase.sol";
import {PermissionFlags, PermissionFlag} from "../../../src/hooks/permissionedPools/libraries/PermissionFlags.sol";
import {PathKey} from "../../../src/libraries/PathKey.sol";

contract PermissionedV4RouterTest is PermissionedRoutingTestHelpers {
    using PermitHash for IAllowanceTransfer.PermitSingle;

    // To allow testing without importing PermissionedV4Router
    error HookNotImplemented();
    error Unauthorized();
    error HookCallFailed();
    error CommandNotImplemented();
    error SliceOutOfBounds();
    error ExecutionFailed(uint256 commandIndex, bytes output);

    Currency public wrappedCurrency0;
    Currency public wrappedCurrency1;

    // Test Users
    address public alice = makeAddr("ALICE");
    address public unauthorizedUser = makeAddr("UNAUTHORIZED");

    // Commands
    bytes public COMMAND_V4_SWAP = hex"10";
    bytes public COMMAND_PERMIT2_PERMIT = hex"0a";

    function setUp() public {
        setupPermissionedRouterCurrenciesAndPoolsWithLiquidity(alice);

        wrappedCurrency0 = Currency.wrap(address(wrappedToken0));
        wrappedCurrency1 = Currency.wrap(address(wrappedToken1));

        plan = Planner.init();

        setupPermissionsAndApprovals();
    }

    function setupPermissionsAndApprovals() internal {
        // Setup approvals for test address
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
        IERC20(Currency.unwrap(currency0)).approve(address(permissionedHooks), type(uint160).max);
        IERC20(Currency.unwrap(currency1)).approve(address(permissionedHooks), type(uint160).max);
        IERC20(Currency.unwrap(currency0)).approve(address(positionManager), type(uint160).max);
        IERC20(Currency.unwrap(currency1)).approve(address(positionManager), type(uint160).max);

        permit2.approve(Currency.unwrap(currency0), address(permissionedRouter), type(uint160).max, 2 ** 47);
        permit2.approve(Currency.unwrap(currency1), address(permissionedRouter), type(uint160).max, 2 ** 47);
        permit2.approve(Currency.unwrap(currency0), address(permissionedHooks), type(uint160).max, 2 ** 47);
        permit2.approve(Currency.unwrap(currency1), address(permissionedHooks), type(uint160).max, 2 ** 47);
        permit2.approve(Currency.unwrap(currency0), address(positionManager), type(uint160).max, 2 ** 47);
        permit2.approve(Currency.unwrap(currency1), address(positionManager), type(uint160).max, 2 ** 47);
    }

    function getInputAndOutputBalances(PoolKey memory poolKey, bool zeroForOne, address manager_)
        public
        view
        returns (uint256 inputBalance, uint256 outputBalance, uint256 ethBalance)
    {
        if (zeroForOne) {
            inputBalance = poolKey.currency0.balanceOf(manager_);
            outputBalance = poolKey.currency1.balanceOf(manager_);
        } else {
            inputBalance = poolKey.currency1.balanceOf(manager_);
            outputBalance = poolKey.currency0.balanceOf(manager_);
        }
        ethBalance = address(this).balance;
    }

    function getInputAndOutputBalancesPath(Currency[] memory path, address manager_)
        public
        view
        returns (uint256 inputBalance, uint256 outputBalance, uint256 ethBalance)
    {
        inputBalance = path[0].balanceOf(manager_);
        outputBalance = path[path.length - 1].balanceOf(manager_);
        ethBalance = address(this).balance;
    }

    function test_gas_swapExactInputSingle_permissionedTokens() public {
        uint256 amountIn = 1000;
        PoolKey memory wrappedKey = PoolKey(wrappedCurrency1, wrappedCurrency0, 3000, 60, permissionedHooks);

        IV4Router.ExactInputSingleParams memory params =
            IV4Router.ExactInputSingleParams(wrappedKey, true, uint128(amountIn), 0, bytes(""));

        plan = plan.add(Actions.SWAP_EXACT_IN_SINGLE, abi.encode(params));
        bytes memory data = plan.finalizeSwap(wrappedCurrency1, wrappedCurrency0, ActionConstants.MSG_SENDER);

        permissionedRouter.execute(COMMAND_V4_SWAP, toBytesArray(data), type(uint256).max);
        vm.snapshotGasLastCall("PermissionedV4Router_ExactInputSingle_PermissionedTokens");
    }

    /*//////////////////////////////////////////////////////////////
                        PERMISSION TESTS
    //////////////////////////////////////////////////////////////*/

    function test_swap_reverts_unauthorized_user() public {
        MockPermissionedToken(Currency.unwrap(currency0)).setAllowlist(unauthorizedUser, PermissionFlags.ALL_ALLOWED);
        MockPermissionedToken(Currency.unwrap(currency1)).setAllowlist(unauthorizedUser, PermissionFlags.ALL_ALLOWED);
        IERC20(Currency.unwrap(currency0)).transfer(unauthorizedUser, 2 ether);
        IERC20(Currency.unwrap(currency1)).transfer(unauthorizedUser, 2 ether);
        MockPermissionedToken(Currency.unwrap(currency0)).setAllowlist(unauthorizedUser, PermissionFlags.NONE);
        MockPermissionedToken(Currency.unwrap(currency1)).setAllowlist(unauthorizedUser, PermissionFlags.NONE);

        Currency currencyA = wrappedCurrency0;
        Currency currencyB = wrappedCurrency1;
        if (Currency.unwrap(currencyA) > Currency.unwrap(currencyB)) (currencyA, currencyB) = (currencyB, currencyA);

        uint256 amountIn = 1 ether;
        PoolKey memory wrappedKey = PoolKey(currencyA, currencyB, 3000, 60, permissionedHooks);

        IV4Router.ExactInputSingleParams memory params =
            IV4Router.ExactInputSingleParams(wrappedKey, true, uint128(amountIn), 0, bytes(""));

        plan = plan.add(Actions.SWAP_EXACT_IN_SINGLE, abi.encode(params));
        bytes memory data = plan.finalizeSwap(currencyA, currencyB, ActionConstants.MSG_SENDER);

        vm.prank(unauthorizedUser);
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(permissionedHooks),
                IHooks.beforeSwap.selector,
                abi.encodeWithSelector(Unauthorized.selector),
                abi.encodeWithSelector(HookCallFailed.selector)
            )
        );
        permissionedRouter.execute(COMMAND_V4_SWAP, toBytesArray(data), type(uint256).max);
    }

    function test_swap_authorized_user() public {
        IERC20(Currency.unwrap(currency0)).transfer(alice, 2 ether);
        IERC20(Currency.unwrap(currency1)).transfer(alice, 2 ether);

        uint256 amountIn = 100;
        PoolKey memory wrappedKey = PoolKey(wrappedCurrency1, wrappedCurrency0, 3000, 60, permissionedHooks);

        IV4Router.ExactInputSingleParams memory params =
            IV4Router.ExactInputSingleParams(wrappedKey, true, uint128(amountIn), 0, bytes(""));

        plan = plan.add(Actions.SWAP_EXACT_IN_SINGLE, abi.encode(params));
        bytes memory data = plan.finalizeSwap(wrappedCurrency1, wrappedCurrency0, ActionConstants.MSG_SENDER);

        vm.prank(alice);
        permissionedRouter.execute(COMMAND_V4_SWAP, toBytesArray(data), type(uint256).max);
    }

    function test_swap_authorized_router() public {
        IERC20(Currency.unwrap(currency0)).transfer(alice, 2 ether);
        IERC20(Currency.unwrap(currency1)).transfer(alice, 2 ether);

        uint256 amountIn = 100;
        uint256 expectedAmountOut = 98;
        PoolKey memory wrappedKey = PoolKey(wrappedCurrency1, wrappedCurrency0, 3000, 60, permissionedHooks);

        IV4Router.ExactInputSingleParams memory params =
            IV4Router.ExactInputSingleParams(wrappedKey, true, uint128(amountIn), 0, bytes(""));

        plan = plan.add(Actions.SWAP_EXACT_IN_SINGLE, abi.encode(params));
        bytes memory data = plan.finalizeSwap(wrappedCurrency1, wrappedCurrency0, ActionConstants.MSG_SENDER);

        (uint256 inputBalanceBefore, uint256 outputBalanceBefore,) =
            getInputAndOutputBalances(wrappedKey, true, address(manager));
        vm.prank(alice);
        permissionedRouter.execute(COMMAND_V4_SWAP, toBytesArray(data), type(uint256).max);
        (uint256 inputBalanceAfter, uint256 outputBalanceAfter,) =
            getInputAndOutputBalances(wrappedKey, true, address(manager));

        assertEq(inputBalanceAfter - inputBalanceBefore, amountIn);
        assertEq(outputBalanceBefore - outputBalanceAfter, expectedAmountOut);
    }

    function test_swap_unauthorized_router_reverts() public {
        IERC20(Currency.unwrap(currency0)).transfer(alice, 2 ether);
        IERC20(Currency.unwrap(currency1)).transfer(alice, 2 ether);

        uint256 amountIn = 100;
        PoolKey memory wrappedKey = PoolKey(wrappedCurrency1, wrappedCurrency0, 3000, 60, permissionedHooks);

        IV4Router.ExactInputSingleParams memory params =
            IV4Router.ExactInputSingleParams(wrappedKey, true, uint128(amountIn), 0, bytes(""));

        plan = plan.add(Actions.SWAP_EXACT_IN_SINGLE, abi.encode(params));
        bytes memory data = plan.finalizeSwap(wrappedCurrency1, wrappedCurrency0, ActionConstants.MSG_SENDER);

        wrappedToken0.updateAllowedWrapper(address(permissionedRouter), false);
        wrappedToken1.updateAllowedWrapper(address(permissionedRouter), false);

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(permissionedHooks),
                IHooks.beforeSwap.selector,
                abi.encodeWithSelector(Unauthorized.selector),
                abi.encodeWithSelector(HookCallFailed.selector)
            )
        );
        permissionedRouter.execute(COMMAND_V4_SWAP, toBytesArray(data), type(uint256).max);
    }

    function test_swap_succeeds_authorized_user_mixed_entry() public {
        uint256 amountIn = 100;
        uint256 expectedAmountOut = 98;
        bool zeroToOne = wrappedCurrency1 == key1.currency0;
        Currency inputCurrency;
        Currency outputCurrency;

        if (zeroToOne) {
            inputCurrency = key1.currency0;
            outputCurrency = key1.currency1;
            getPermissionedCurrency(key1.currency0).transfer(alice, 2 ether);
        } else {
            inputCurrency = key1.currency1;
            outputCurrency = key1.currency0;
            getPermissionedCurrency(key1.currency1).transfer(alice, 2 ether);
        }
        IV4Router.ExactInputSingleParams memory params =
            IV4Router.ExactInputSingleParams(key1, zeroToOne, uint128(amountIn), 0, bytes(""));

        plan = plan.add(Actions.SWAP_EXACT_IN_SINGLE, abi.encode(params));
        bytes memory data = plan.finalizeSwap(inputCurrency, outputCurrency, ActionConstants.MSG_SENDER);

        (uint256 inputBalanceBefore, uint256 outputBalanceBefore,) =
            getInputAndOutputBalances(key1, zeroToOne, address(manager));
        vm.prank(alice);
        permissionedRouter.execute(COMMAND_V4_SWAP, toBytesArray(data), type(uint256).max);
        (uint256 inputBalanceAfter, uint256 outputBalanceAfter,) =
            getInputAndOutputBalances(key1, zeroToOne, address(manager));

        assertEq(inputBalanceAfter - inputBalanceBefore, amountIn);
        assertEq(outputBalanceBefore - outputBalanceAfter, expectedAmountOut);
    }

    function test_swap_succeeds_authorized_user_mixed_exit() public {
        IERC20(Currency.unwrap(currency2)).transfer(alice, 2 ether);

        uint256 amountIn = 100;
        uint256 expectedAmountOut = 98;
        bool zeroToOne = !(wrappedCurrency1 == key1.currency0);
        Currency inputCurrency;
        Currency outputCurrency;

        if (zeroToOne) {
            inputCurrency = key1.currency0;
            outputCurrency = key1.currency1;
            getPermissionedCurrency(key1.currency0).transfer(alice, 2 ether);
        } else {
            inputCurrency = key1.currency1;
            outputCurrency = key1.currency0;
            getPermissionedCurrency(key1.currency1).transfer(alice, 2 ether);
        }

        IV4Router.ExactInputSingleParams memory params =
            IV4Router.ExactInputSingleParams(key1, zeroToOne, uint128(amountIn), 0, bytes(""));

        plan = plan.add(Actions.SWAP_EXACT_IN_SINGLE, abi.encode(params));
        bytes memory data = plan.finalizeSwap(inputCurrency, outputCurrency, ActionConstants.MSG_SENDER);

        (uint256 inputBalanceBefore, uint256 outputBalanceBefore,) =
            getInputAndOutputBalances(key1, zeroToOne, address(manager));
        vm.prank(alice);
        permissionedRouter.execute(COMMAND_V4_SWAP, toBytesArray(data), type(uint256).max);
        (uint256 inputBalanceAfter, uint256 outputBalanceAfter,) =
            getInputAndOutputBalances(key1, zeroToOne, address(manager));

        assertEq(inputBalanceAfter - inputBalanceBefore, amountIn);
        assertEq(outputBalanceBefore - outputBalanceAfter, expectedAmountOut);
    }

    function test_swap_succeeds_unauthorized_user_mixed_entry() public {
        bool zeroToOne = wrappedCurrency1 == key1.currency0;
        Currency inputCurrency;
        Currency outputCurrency;

        if (zeroToOne) {
            inputCurrency = key1.currency0;
            outputCurrency = key1.currency1;
            getPermissionedCurrency(key1.currency0).transfer(alice, 2 ether);
        } else {
            inputCurrency = key1.currency1;
            outputCurrency = key1.currency0;
            getPermissionedCurrency(key1.currency1).transfer(alice, 2 ether);
        }

        // Give unauthorized user the permissioned currency
        MockPermissionedToken(Currency.unwrap(currency1)).setAllowlist(unauthorizedUser, PermissionFlags.ALL_ALLOWED);
        IERC20(Currency.unwrap(currency1)).transfer(unauthorizedUser, 2 ether);
        MockPermissionedToken(Currency.unwrap(currency1)).setAllowlist(unauthorizedUser, PermissionFlags.NONE);

        uint256 amountIn = 100;

        IV4Router.ExactInputSingleParams memory params =
            IV4Router.ExactInputSingleParams(key1, zeroToOne, uint128(amountIn), 0, bytes(""));

        plan = plan.add(Actions.SWAP_EXACT_IN_SINGLE, abi.encode(params));
        bytes memory data = plan.finalizeSwap(inputCurrency, outputCurrency, ActionConstants.MSG_SENDER);

        vm.prank(unauthorizedUser);
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(permissionedHooks),
                IHooks.beforeSwap.selector,
                abi.encodeWithSelector(Unauthorized.selector),
                abi.encodeWithSelector(HookCallFailed.selector)
            )
        );
        permissionedRouter.execute(COMMAND_V4_SWAP, toBytesArray(data), type(uint256).max);
    }

    function test_swap_unauthorized_user_mixed_exit_reverts() public {
        IERC20(Currency.unwrap(currency2)).transfer(unauthorizedUser, 2 ether);

        uint256 amountIn = 100;
        bool zeroToOne = !(wrappedCurrency1 == key1.currency0);
        Currency inputCurrency;
        Currency outputCurrency;

        if (zeroToOne) {
            inputCurrency = key1.currency0;
            outputCurrency = key1.currency1;
            getPermissionedCurrency(key1.currency0).transfer(alice, 2 ether);
        } else {
            inputCurrency = key1.currency1;
            outputCurrency = key1.currency0;
            getPermissionedCurrency(key1.currency1).transfer(alice, 2 ether);
        }

        IV4Router.ExactInputSingleParams memory params =
            IV4Router.ExactInputSingleParams(key1, zeroToOne, uint128(amountIn), 0, bytes(""));

        plan = plan.add(Actions.SWAP_EXACT_IN_SINGLE, abi.encode(params));
        bytes memory data = plan.finalizeSwap(inputCurrency, outputCurrency, ActionConstants.MSG_SENDER);

        vm.prank(unauthorizedUser);
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(permissionedHooks),
                IHooks.beforeSwap.selector,
                abi.encodeWithSelector(Unauthorized.selector),
                abi.encodeWithSelector(HookCallFailed.selector)
            )
        );
        permissionedRouter.execute(COMMAND_V4_SWAP, toBytesArray(data), type(uint256).max);
    }

    function test_permission_flag_none_swap_reverts() public {
        // Test that NONE permissions prevent swap operations
        MockPermissionedToken(Currency.unwrap(currency0)).setAllowlist(alice, PermissionFlags.NONE);
        MockPermissionedToken(Currency.unwrap(currency1)).setAllowlist(alice, PermissionFlags.NONE);

        uint256 amountIn = 100;
        PoolKey memory wrappedKey = PoolKey(wrappedCurrency1, wrappedCurrency0, 3000, 60, permissionedHooks);

        IV4Router.ExactInputSingleParams memory params =
            IV4Router.ExactInputSingleParams(wrappedKey, true, uint128(amountIn), 0, bytes(""));

        plan = plan.add(Actions.SWAP_EXACT_IN_SINGLE, abi.encode(params));
        bytes memory data = plan.finalizeSwap(wrappedCurrency1, wrappedCurrency0, ActionConstants.MSG_SENDER);

        vm.prank(alice);
        vm.expectRevert();
        permissionedRouter.execute(COMMAND_V4_SWAP, toBytesArray(data), type(uint256).max);
    }

    function test_permission_flag_swap_allowed_succeeds() public {
        // Test that SWAP_ALLOWED allows swap operations
        MockPermissionedToken(Currency.unwrap(currency0)).setAllowlist(alice, PermissionFlags.SWAP_ALLOWED);
        MockPermissionedToken(Currency.unwrap(currency1)).setAllowlist(alice, PermissionFlags.SWAP_ALLOWED);

        IERC20(Currency.unwrap(currency0)).transfer(alice, 2 ether);
        IERC20(Currency.unwrap(currency1)).transfer(alice, 2 ether);

        uint256 amountIn = 100;
        PoolKey memory wrappedKey = PoolKey(wrappedCurrency1, wrappedCurrency0, 3000, 60, permissionedHooks);

        IV4Router.ExactInputSingleParams memory params =
            IV4Router.ExactInputSingleParams(wrappedKey, true, uint128(amountIn), 0, bytes(""));

        plan = plan.add(Actions.SWAP_EXACT_IN_SINGLE, abi.encode(params));
        bytes memory data = plan.finalizeSwap(wrappedCurrency1, wrappedCurrency0, ActionConstants.MSG_SENDER);

        vm.prank(alice);
        permissionedRouter.execute(COMMAND_V4_SWAP, toBytesArray(data), type(uint256).max);
    }

    function test_permission_flag_liquidity_allowed_swap_reverts() public {
        // Test that LIQUIDITY_ALLOWED does not allow swap operations
        MockPermissionedToken(Currency.unwrap(currency0)).setAllowlist(alice, PermissionFlags.LIQUIDITY_ALLOWED);
        MockPermissionedToken(Currency.unwrap(currency1)).setAllowlist(alice, PermissionFlags.LIQUIDITY_ALLOWED);

        IERC20(Currency.unwrap(currency0)).transfer(alice, 2 ether);
        IERC20(Currency.unwrap(currency1)).transfer(alice, 2 ether);

        uint256 amountIn = 100;
        PoolKey memory wrappedKey = PoolKey(wrappedCurrency1, wrappedCurrency0, 3000, 60, permissionedHooks);

        IV4Router.ExactInputSingleParams memory params =
            IV4Router.ExactInputSingleParams(wrappedKey, true, uint128(amountIn), 0, bytes(""));

        plan = plan.add(Actions.SWAP_EXACT_IN_SINGLE, abi.encode(params));
        bytes memory data = plan.finalizeSwap(wrappedCurrency1, wrappedCurrency0, ActionConstants.MSG_SENDER);

        vm.prank(alice);
        vm.expectRevert();
        permissionedRouter.execute(COMMAND_V4_SWAP, toBytesArray(data), type(uint256).max);
    }

    function test_permission_flag_all_allowed_swap_succeeds() public {
        // Test that ALL_ALLOWED allows swap operations
        MockPermissionedToken(Currency.unwrap(currency0)).setAllowlist(alice, PermissionFlags.ALL_ALLOWED);
        MockPermissionedToken(Currency.unwrap(currency1)).setAllowlist(alice, PermissionFlags.ALL_ALLOWED);

        IERC20(Currency.unwrap(currency0)).transfer(alice, 2 ether);
        IERC20(Currency.unwrap(currency1)).transfer(alice, 2 ether);

        uint256 amountIn = 100;
        PoolKey memory wrappedKey = PoolKey(wrappedCurrency1, wrappedCurrency0, 3000, 60, permissionedHooks);

        IV4Router.ExactInputSingleParams memory params =
            IV4Router.ExactInputSingleParams(wrappedKey, true, uint128(amountIn), 0, bytes(""));

        plan = plan.add(Actions.SWAP_EXACT_IN_SINGLE, abi.encode(params));
        bytes memory data = plan.finalizeSwap(wrappedCurrency1, wrappedCurrency0, ActionConstants.MSG_SENDER);

        vm.prank(alice);
        permissionedRouter.execute(COMMAND_V4_SWAP, toBytesArray(data), type(uint256).max);
    }

    function test_permission_flag_combinations_swap() public {
        // Test various combinations of permissions for swaps
        IERC20(Currency.unwrap(currency0)).transfer(alice, 2 ether);
        IERC20(Currency.unwrap(currency1)).transfer(alice, 2 ether);

        uint256 amountIn = 100;
        PoolKey memory wrappedKey = PoolKey(wrappedCurrency1, wrappedCurrency0, 3000, 60, permissionedHooks);

        IV4Router.ExactInputSingleParams memory params =
            IV4Router.ExactInputSingleParams(wrappedKey, true, uint128(amountIn), 0, bytes(""));

        plan = plan.add(Actions.SWAP_EXACT_IN_SINGLE, abi.encode(params));
        bytes memory data = plan.finalizeSwap(wrappedCurrency1, wrappedCurrency0, ActionConstants.MSG_SENDER);

        // Test SWAP_ALLOWED + LIQUIDITY_ALLOWED (should work like ALL_ALLOWED)
        MockPermissionedToken(Currency.unwrap(currency0)).setAllowlist(
            alice, (PermissionFlags.SWAP_ALLOWED | PermissionFlags.LIQUIDITY_ALLOWED)
        );
        MockPermissionedToken(Currency.unwrap(currency1)).setAllowlist(
            alice, (PermissionFlags.SWAP_ALLOWED | PermissionFlags.LIQUIDITY_ALLOWED)
        );

        vm.prank(alice);
        permissionedRouter.execute(COMMAND_V4_SWAP, toBytesArray(data), type(uint256).max);
    }

    function test_permission_flag_partial_permissions_swap() public {
        // Test that having permissions on only one token is not enough for swaps
        MockPermissionedToken(Currency.unwrap(currency0)).setAllowlist(alice, PermissionFlags.SWAP_ALLOWED);
        MockPermissionedToken(Currency.unwrap(currency1)).setAllowlist(alice, PermissionFlags.NONE);

        IERC20(Currency.unwrap(currency0)).transfer(alice, 2 ether);
        IERC20(Currency.unwrap(currency1)).transfer(alice, 2 ether);

        uint256 amountIn = 100;
        PoolKey memory wrappedKey = PoolKey(wrappedCurrency1, wrappedCurrency0, 3000, 60, permissionedHooks);

        IV4Router.ExactInputSingleParams memory params =
            IV4Router.ExactInputSingleParams(wrappedKey, true, uint128(amountIn), 0, bytes(""));

        plan = plan.add(Actions.SWAP_EXACT_IN_SINGLE, abi.encode(params));
        bytes memory data = plan.finalizeSwap(wrappedCurrency1, wrappedCurrency0, ActionConstants.MSG_SENDER);

        vm.prank(alice);
        vm.expectRevert();
        permissionedRouter.execute(COMMAND_V4_SWAP, toBytesArray(data), type(uint256).max);
    }

    function test_permission_flag_dynamic_changes_swap() public {
        // Test that permission changes take effect immediately for swaps
        MockPermissionedToken(Currency.unwrap(currency0)).setAllowlist(alice, PermissionFlags.SWAP_ALLOWED);
        MockPermissionedToken(Currency.unwrap(currency1)).setAllowlist(alice, PermissionFlags.SWAP_ALLOWED);

        IERC20(Currency.unwrap(currency0)).transfer(alice, 2 ether);
        IERC20(Currency.unwrap(currency1)).transfer(alice, 2 ether);

        uint256 amountIn = 100;
        PoolKey memory wrappedKey = PoolKey(wrappedCurrency1, wrappedCurrency0, 3000, 60, permissionedHooks);

        IV4Router.ExactInputSingleParams memory params =
            IV4Router.ExactInputSingleParams(wrappedKey, true, uint128(amountIn), 0, bytes(""));

        plan = plan.add(Actions.SWAP_EXACT_IN_SINGLE, abi.encode(params));
        bytes memory data = plan.finalizeSwap(wrappedCurrency1, wrappedCurrency0, ActionConstants.MSG_SENDER);

        // Should succeed initially
        vm.prank(alice);
        permissionedRouter.execute(COMMAND_V4_SWAP, toBytesArray(data), type(uint256).max);

        // Remove permissions
        MockPermissionedToken(Currency.unwrap(currency0)).setAllowlist(alice, PermissionFlags.NONE);
        MockPermissionedToken(Currency.unwrap(currency1)).setAllowlist(alice, PermissionFlags.NONE);

        // Should fail on subsequent operations
        vm.prank(alice);
        vm.expectRevert();
        permissionedRouter.execute(COMMAND_V4_SWAP, toBytesArray(data), type(uint256).max);
    }

    function test_permission_flag_edge_cases_swap() public {
        // Test edge cases with permission flags for swaps
        IERC20(Currency.unwrap(currency0)).transfer(alice, 2 ether);
        IERC20(Currency.unwrap(currency1)).transfer(alice, 2 ether);

        uint256 amountIn = 100;
        PoolKey memory wrappedKey = PoolKey(wrappedCurrency1, wrappedCurrency0, 3000, 60, permissionedHooks);

        IV4Router.ExactInputSingleParams memory params =
            IV4Router.ExactInputSingleParams(wrappedKey, true, uint128(amountIn), 0, bytes(""));

        plan = plan.add(Actions.SWAP_EXACT_IN_SINGLE, abi.encode(params));
        bytes memory data = plan.finalizeSwap(wrappedCurrency1, wrappedCurrency0, ActionConstants.MSG_SENDER);

        // Test with zero permissions (should be same as NONE)
        MockPermissionedToken(Currency.unwrap(currency0)).setAllowlist(alice, PermissionFlag.wrap(0x0000));
        MockPermissionedToken(Currency.unwrap(currency1)).setAllowlist(alice, PermissionFlag.wrap(0x0000));

        vm.prank(alice);
        vm.expectRevert();
        permissionedRouter.execute(COMMAND_V4_SWAP, toBytesArray(data), type(uint256).max);

        // Test with maximum permissions (should be same as ALL_ALLOWED)
        MockPermissionedToken(Currency.unwrap(currency0)).setAllowlist(alice, PermissionFlag.wrap(0xFFFF));
        MockPermissionedToken(Currency.unwrap(currency1)).setAllowlist(alice, PermissionFlag.wrap(0xFFFF));

        vm.prank(alice);
        permissionedRouter.execute(COMMAND_V4_SWAP, toBytesArray(data), type(uint256).max);
    }

    function test_permission_flag_all_pool_types_swap() public {
        MockPermissionedToken(Currency.unwrap(getPermissionedCurrency(wrappedCurrency0))).setAllowlist(
            alice, PermissionFlags.SWAP_ALLOWED
        );
        MockPermissionedToken(Currency.unwrap(getPermissionedCurrency(wrappedCurrency1))).setAllowlist(
            alice, PermissionFlags.SWAP_ALLOWED
        );

        _test_permission_flag_all_pool_types_swap(key0);
        _test_permission_flag_all_pool_types_swap(key1);
        _test_permission_flag_all_pool_types_swap(key2);
    }

    function _test_permission_flag_all_pool_types_swap(PoolKey memory poolKey) public {
        IERC20(Currency.unwrap(getPermissionedCurrency(poolKey.currency0))).transfer(alice, 2 ether);
        IERC20(Currency.unwrap(getPermissionedCurrency(poolKey.currency1))).transfer(alice, 2 ether);

        uint256 amountIn = 100;
        plan = Planner.init();
        IV4Router.ExactInputSingleParams memory params =
            IV4Router.ExactInputSingleParams(poolKey, true, uint128(amountIn), 0, bytes(""));
        plan = plan.add(Actions.SWAP_EXACT_IN_SINGLE, abi.encode(params));
        plan = plan.add(Actions.SETTLE, abi.encode(poolKey.currency0, ActionConstants.CONTRACT_BALANCE, false));
        plan = plan.add(Actions.TAKE_ALL, abi.encode(poolKey.currency1, 0));
        bytes memory data = plan.finalizeSwap(poolKey.currency0, poolKey.currency1, ActionConstants.MSG_SENDER);

        vm.prank(alice);
        permissionedRouter.execute(COMMAND_V4_SWAP, toBytesArray(data), type(uint256).max);
    }

    function test_permission_flag_exact_output_swap() public {
        // Test permission flags with exact output swaps
        MockPermissionedToken(Currency.unwrap(currency0)).setAllowlist(alice, PermissionFlags.SWAP_ALLOWED);
        MockPermissionedToken(Currency.unwrap(currency1)).setAllowlist(alice, PermissionFlags.SWAP_ALLOWED);

        IERC20(Currency.unwrap(currency0)).transfer(alice, 2 ether);
        IERC20(Currency.unwrap(currency1)).transfer(alice, 2 ether);

        uint256 amountOut = 50;
        uint256 amountInMaximum = 100;
        PoolKey memory wrappedKey = PoolKey(wrappedCurrency1, wrappedCurrency0, 3000, 60, permissionedHooks);

        IV4Router.ExactOutputSingleParams memory params =
            IV4Router.ExactOutputSingleParams(wrappedKey, true, uint128(amountOut), uint128(amountInMaximum), bytes(""));

        plan = plan.add(Actions.SWAP_EXACT_OUT_SINGLE, abi.encode(params));
        bytes memory data = plan.finalizeSwap(wrappedCurrency1, wrappedCurrency0, ActionConstants.MSG_SENDER);

        vm.prank(alice);
        permissionedRouter.execute(COMMAND_V4_SWAP, toBytesArray(data), type(uint256).max);
    }

    function test_permission_flag_multi_hop_swap() public {
        // Test permission flags with multi-hop swaps
        MockPermissionedToken(Currency.unwrap(currency0)).setAllowlist(alice, PermissionFlags.SWAP_ALLOWED);
        MockPermissionedToken(Currency.unwrap(currency1)).setAllowlist(alice, PermissionFlags.SWAP_ALLOWED);

        IERC20(Currency.unwrap(currency0)).transfer(alice, 2 ether);
        IERC20(Currency.unwrap(currency1)).transfer(alice, 2 ether);

        uint256 amountIn = 100;
        Currency[] memory path = new Currency[](2);
        path[0] = wrappedCurrency1;
        path[1] = wrappedCurrency0;

        // Create path keys for the multi-hop swap
        PathKey[] memory pathKeys = new PathKey[](1);
        pathKeys[0] = PathKey({
            intermediateCurrency: wrappedCurrency0,
            fee: 3000,
            tickSpacing: 60,
            hooks: permissionedHooks,
            hookData: bytes("")
        });

        IV4Router.ExactInputParams memory params =
            IV4Router.ExactInputParams(wrappedCurrency1, pathKeys, uint128(amountIn), 0);

        plan = plan.add(Actions.SWAP_EXACT_IN, abi.encode(params));
        bytes memory data = plan.finalizeSwap(wrappedCurrency1, wrappedCurrency0, ActionConstants.MSG_SENDER);

        vm.prank(alice);
        permissionedRouter.execute(COMMAND_V4_SWAP, toBytesArray(data), type(uint256).max);
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
        permissionedRouter.execute(COMMAND_V4_SWAP, toBytesArray(data), type(uint256).max);
    }

    function test_swapExactInputSingle_zeroForOne_takeToMsgSender() public {
        uint256 amountIn = 1 ether;
        uint256 expectedAmountOut = 19992;

        IV4Router.ExactInputSingleParams memory params =
            IV4Router.ExactInputSingleParams(key0, true, uint128(amountIn), 0, bytes(""));

        plan = plan.add(Actions.SWAP_EXACT_IN_SINGLE, abi.encode(params));
        (uint256 inputBalanceBefore, uint256 outputBalanceBefore,) =
            getInputAndOutputBalances(key0, true, address(manager));
        (
            uint256 userInputBalanceBefore,
            uint256 userOutputBalanceBefore,
            uint256 userInputBalanceAfter,
            uint256 userOutputBalanceAfter
        ) = _finalizeAndExecuteSwap(key0.currency0, key0.currency1, amountIn);
        (uint256 inputBalanceAfter, uint256 outputBalanceAfter,) =
            getInputAndOutputBalances(key0, true, address(manager));

        assertEq(userInputBalanceBefore - userInputBalanceAfter, amountIn);
        assertEq(userOutputBalanceAfter - userOutputBalanceBefore, expectedAmountOut);
        assertEq(inputBalanceAfter - inputBalanceBefore, amountIn);
        assertEq(outputBalanceBefore - outputBalanceAfter, expectedAmountOut);
    }

    function test_swapExactInputSingle_zeroForOne_takeToRecipient() public {
        uint256 amountIn = 1 ether;
        uint256 expectedAmountOut = 19992;

        IV4Router.ExactInputSingleParams memory params =
            IV4Router.ExactInputSingleParams(key0, true, uint128(amountIn), 0, bytes(""));

        plan = plan.add(Actions.SWAP_EXACT_IN_SINGLE, abi.encode(params));

        uint256 aliceOutputBalanceBefore = getPermissionedCurrency(key0.currency1).balanceOf(alice);

        (uint256 inputBalanceBefore, uint256 outputBalanceBefore,) =
            getInputAndOutputBalances(key0, true, address(manager));
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

        IV4Router.ExactInputSingleParams memory params =
            IV4Router.ExactInputSingleParams(key0, true, uint128(amountIn), 0, bytes(""));

        Currency inputCurrency = getPermissionedCurrency(key0.currency0);
        Currency outputCurrency = getPermissionedCurrency(key0.currency1);

        plan = plan.add(Actions.SWAP_EXACT_IN_SINGLE, abi.encode(params));
        plan = plan.add(Actions.SETTLE_ALL, abi.encode(key0.currency0, expectedAmountOut * 12 / 10));
        // take the entire open delta to the router's address
        plan =
            plan.add(Actions.TAKE, abi.encode(key0.currency1, ActionConstants.ADDRESS_THIS, ActionConstants.OPEN_DELTA));
        bytes memory data = plan.encode();
        // the router holds no funds before
        assertEq(inputCurrency.balanceOf(address(permissionedRouter)), 0);
        assertEq(outputCurrency.balanceOf(address(permissionedRouter)), 0);

        permissionedRouter.execute(COMMAND_V4_SWAP, toBytesArray(data), type(uint256).max);
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
        (
            uint256 userInputBalanceBefore,
            uint256 userOutputBalanceBefore,
            uint256 userInputBalanceAfter,
            uint256 userOutputBalanceAfter
        ) = _finalizeAndExecuteSwap(key0.currency1, key0.currency0, amountIn);
        (uint256 inputBalanceAfter, uint256 outputBalanceAfter,) =
            getInputAndOutputBalances(key0, zeroForOne, address(manager));

        assertEq(key0.currency0.balanceOf(address(permissionedRouter)), 0);
        assertEq(key0.currency1.balanceOf(address(permissionedRouter)), 0);
        assertEq(userInputBalanceBefore - userInputBalanceAfter, amountIn);
        assertEq(userOutputBalanceAfter - userOutputBalanceBefore, expectedAmountOut);
        assertEq(inputBalanceAfter - inputBalanceBefore, amountIn);
        assertEq(outputBalanceBefore - outputBalanceAfter, expectedAmountOut);
    }

    function test_swapExactInput_revertsForAmountOut() public {
        uint256 amountIn = 1000;
        uint256 expectedAmountOut = 949;

        tokenPath.push(wrappedCurrency0);
        tokenPath.push(wrappedCurrency1);

        IV4Router.ExactInputParams memory params =
            _getExactInputParamsWithHook(tokenPath, amountIn, address(permissionedHooks), expectedAmountOut);
        params.amountOutMinimum = uint128(expectedAmountOut + 1);

        plan = plan.add(Actions.SWAP_EXACT_IN, abi.encode(params));
        bytes memory data = plan.finalizeSwap(key0.currency0, key0.currency1, ActionConstants.MSG_SENDER);

        vm.expectRevert(
            abi.encodeWithSelector(IV4Router.V4TooLittleReceived.selector, expectedAmountOut + 1, expectedAmountOut)
        );
        permissionedRouter.execute(COMMAND_V4_SWAP, toBytesArray(data), type(uint256).max);
    }

    function test_swapExactIn_1Hop_zeroForOne() public {
        uint256 amountIn = 1 ether;
        uint256 expectedAmountOut = 19992;

        tokenPath.push(wrappedCurrency0);
        tokenPath.push(wrappedCurrency1);

        IV4Router.ExactInputParams memory params =
            _getExactInputParamsWithHook(tokenPath, amountIn, address(permissionedHooks), expectedAmountOut);

        plan = plan.add(Actions.SWAP_EXACT_IN, abi.encode(params));
        (uint256 inputBalanceBefore, uint256 outputBalanceBefore,) =
            getInputAndOutputBalancesPath(tokenPath, address(manager));
        (
            uint256 userInputBalanceBefore,
            uint256 userOutputBalanceBefore,
            uint256 userInputBalanceAfter,
            uint256 userOutputBalanceAfter
        ) = _finalizeAndExecuteSwap(wrappedCurrency0, wrappedCurrency1, amountIn);
        (uint256 inputBalanceAfter, uint256 outputBalanceAfter,) =
            getInputAndOutputBalancesPath(tokenPath, address(manager));

        assertEq(wrappedCurrency0.balanceOf(address(permissionedRouter)), 0);
        assertEq(wrappedCurrency1.balanceOf(address(permissionedRouter)), 0);
        assertEq(userInputBalanceBefore - userInputBalanceAfter, amountIn);
        assertEq(userOutputBalanceAfter - userOutputBalanceBefore, expectedAmountOut);
        assertEq(inputBalanceAfter - inputBalanceBefore, amountIn);
        assertEq(outputBalanceBefore - outputBalanceAfter, expectedAmountOut);
    }

    function test_swapExactIn_1Hop_oneForZero() public {
        uint256 amountIn = 1 ether;
        uint256 expectedAmountOut = 19992;

        tokenPath.push(wrappedCurrency1);
        tokenPath.push(wrappedCurrency0);

        IV4Router.ExactInputParams memory params =
            _getExactInputParamsWithHook(tokenPath, amountIn, address(permissionedHooks), expectedAmountOut);

        plan = plan.add(Actions.SWAP_EXACT_IN, abi.encode(params));

        (uint256 inputBalanceBefore, uint256 outputBalanceBefore,) =
            getInputAndOutputBalancesPath(tokenPath, address(manager));
        (
            uint256 userInputBalanceBefore,
            uint256 userOutputBalanceBefore,
            uint256 userInputBalanceAfter,
            uint256 userOutputBalanceAfter
        ) = _finalizeAndExecuteSwap(wrappedCurrency1, wrappedCurrency0, amountIn);
        (uint256 inputBalanceAfter, uint256 outputBalanceAfter,) =
            getInputAndOutputBalancesPath(tokenPath, address(manager));

        assertEq(wrappedCurrency0.balanceOf(address(permissionedRouter)), 0);
        assertEq(wrappedCurrency1.balanceOf(address(permissionedRouter)), 0);
        assertEq(userInputBalanceBefore - userInputBalanceAfter, amountIn);
        assertEq(userOutputBalanceAfter - userOutputBalanceBefore, expectedAmountOut);
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
            _getExactInputParamsWithHook(tokenPath, amountIn, address(permissionedHooks), expectedAmountOut);

        plan = plan.add(Actions.SWAP_EXACT_IN, abi.encode(params));

        uint256 intermediateBalanceBefore = currency1.balanceOfSelf();

        (uint256 inputBalanceBefore, uint256 outputBalanceBefore,) =
            getInputAndOutputBalancesPath(tokenPath, address(manager));
        (
            uint256 userInputBalanceBefore,
            uint256 userOutputBalanceBefore,
            uint256 userInputBalanceAfter,
            uint256 userOutputBalanceAfter
        ) = _finalizeAndExecuteSwap(wrappedCurrency0, currency2, amountIn);
        (uint256 inputBalanceAfter, uint256 outputBalanceAfter,) =
            getInputAndOutputBalancesPath(tokenPath, address(manager));

        // check intermediate token balances
        assertEq(intermediateBalanceBefore, currency1.balanceOfSelf());
        assertEq(wrappedCurrency0.balanceOf(address(permissionedRouter)), 0);
        assertEq(wrappedCurrency1.balanceOf(address(permissionedRouter)), 0);
        assertEq(currency2.balanceOf(address(permissionedRouter)), 0);
        assertEq(userInputBalanceBefore - userInputBalanceAfter, amountIn);
        assertEq(userOutputBalanceAfter - userOutputBalanceBefore, expectedAmountOut);
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
            _getExactInputParamsWithHook(tokenPath, amountIn, address(permissionedHooks), expectedAmountOut);

        plan = plan.add(Actions.SWAP_EXACT_IN, abi.encode(params));

        (uint256 inputBalanceBefore, uint256 outputBalanceBefore,) =
            getInputAndOutputBalancesPath(tokenPath, address(manager));
        (
            uint256 userInputBalanceBefore,
            uint256 userOutputBalanceBefore,
            uint256 userInputBalanceAfter,
            uint256 userOutputBalanceAfter
        ) = _finalizeAndExecuteSwap(wrappedCurrency0, currency3, amountIn);
        (uint256 inputBalanceAfter, uint256 outputBalanceAfter,) =
            getInputAndOutputBalancesPath(tokenPath, address(manager));

        // check intermediate tokens werent left in the router
        assertEq(wrappedCurrency0.balanceOf(address(permissionedRouter)), 0);
        assertEq(wrappedCurrency1.balanceOf(address(permissionedRouter)), 0);
        assertEq(currency2.balanceOf(address(permissionedRouter)), 0);
        assertEq(currency3.balanceOf(address(permissionedRouter)), 0);
        assertEq(userInputBalanceBefore - userInputBalanceAfter, amountIn);
        assertEq(userOutputBalanceAfter - userOutputBalanceBefore, expectedAmountOut);
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
        (
            uint256 userInputBalanceBefore,
            uint256 userOutputBalanceBefore,
            uint256 userInputBalanceAfter,
            uint256 userOutputBalanceAfter
        ) = _finalizeAndExecuteSwap(nativeKey.currency0, nativeKey.currency1, amountIn);
        (, uint256 outputBalanceAfter, uint256 ethBalanceAfter) =
            getInputAndOutputBalances(nativeKey, true, address(manager));

        assertEq(nativeKey.currency0.balanceOf(address(permissionedRouter)), 0);
        assertEq(nativeKey.currency1.balanceOf(address(permissionedRouter)), 0);
        assertEq(userInputBalanceBefore - userInputBalanceAfter, amountIn);
        assertEq(userOutputBalanceAfter - userOutputBalanceBefore, expectedAmountOut);
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
        (
            uint256 userInputBalanceBefore,
            uint256 userOutputBalanceBefore,
            uint256 userInputBalanceAfter,
            uint256 userOutputBalanceAfter
        ) = _finalizeAndExecuteSwap(nativeKey.currency1, nativeKey.currency0, amountIn);
        (uint256 inputBalanceAfter,, uint256 ethBalanceAfter) =
            getInputAndOutputBalances(nativeKey, zeroForOne, address(manager));

        assertEq(nativeKey.currency0.balanceOf(address(permissionedRouter)), 0);
        assertEq(nativeKey.currency1.balanceOf(address(permissionedRouter)), 0);
        assertEq(userInputBalanceBefore - userInputBalanceAfter, amountIn);
        assertEq(userOutputBalanceAfter - userOutputBalanceBefore, expectedAmountOut);
        assertEq(ethBalanceAfter - ethBalanceBefore, expectedAmountOut);
        assertEq(inputBalanceAfter - inputBalanceBefore, amountIn);
    }

    function test_nativeIn_swapExactIn_1Hop() public {
        uint256 amountIn = 1 ether;
        uint256 expectedAmountOut = 19992;

        tokenPath.push(CurrencyLibrary.ADDRESS_ZERO);
        tokenPath.push(nativeKey.currency1);

        IV4Router.ExactInputParams memory params =
            _getExactInputParamsWithHook(tokenPath, amountIn, address(permissionedHooks));

        plan = plan.add(Actions.SWAP_EXACT_IN, abi.encode(params));

        (, uint256 outputBalanceBefore, uint256 ethBalanceBefore) =
            getInputAndOutputBalancesPath(tokenPath, address(manager));
        (
            uint256 userInputBalanceBefore,
            uint256 userOutputBalanceBefore,
            uint256 userInputBalanceAfter,
            uint256 userOutputBalanceAfter
        ) = _finalizeAndExecuteSwap(CurrencyLibrary.ADDRESS_ZERO, nativeKey.currency1, amountIn);
        (, uint256 outputBalanceAfter, uint256 ethBalanceAfter) =
            getInputAndOutputBalancesPath(tokenPath, address(manager));

        assertEq(nativeKey.currency0.balanceOf(address(permissionedRouter)), 0);
        assertEq(nativeKey.currency1.balanceOf(address(permissionedRouter)), 0);
        assertEq(userInputBalanceBefore - userInputBalanceAfter, amountIn);
        assertEq(userOutputBalanceAfter - userOutputBalanceBefore, expectedAmountOut);
        assertEq(ethBalanceBefore - ethBalanceAfter, amountIn);
        assertEq(outputBalanceBefore - outputBalanceAfter, expectedAmountOut);
    }

    function test_nativeOut_swapExactIn_1Hop() public {
        uint256 amountIn = 1 ether;
        uint256 expectedAmountOut = 19992;

        tokenPath.push(nativeKey.currency1);
        tokenPath.push(CurrencyLibrary.ADDRESS_ZERO);

        IV4Router.ExactInputParams memory params =
            _getExactInputParamsWithHook(tokenPath, amountIn, address(permissionedHooks));

        plan = plan.add(Actions.SWAP_EXACT_IN, abi.encode(params));

        (uint256 inputBalanceBefore,, uint256 ethBalanceBefore) =
            getInputAndOutputBalancesPath(tokenPath, address(manager));
        (
            uint256 userInputBalanceBefore,
            uint256 userOutputBalanceBefore,
            uint256 userInputBalanceAfter,
            uint256 userOutputBalanceAfter
        ) = _finalizeAndExecuteSwap(nativeKey.currency1, CurrencyLibrary.ADDRESS_ZERO, amountIn);
        (uint256 inputBalanceAfter,, uint256 ethBalanceAfter) =
            getInputAndOutputBalancesPath(tokenPath, address(manager));

        assertEq(nativeKey.currency0.balanceOf(address(permissionedRouter)), 0);
        assertEq(nativeKey.currency1.balanceOf(address(permissionedRouter)), 0);
        assertEq(userInputBalanceBefore - userInputBalanceAfter, amountIn);
        assertEq(userOutputBalanceAfter - userOutputBalanceBefore, expectedAmountOut);
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
            _getExactInputParamsWithHook(tokenPath, amountIn, address(permissionedHooks));

        plan = plan.add(Actions.SWAP_EXACT_IN, abi.encode(params));

        uint256 intermediateBalanceBefore = currency0.balanceOfSelf();
        (, uint256 outputBalanceBefore, uint256 ethBalanceBefore) =
            getInputAndOutputBalancesPath(tokenPath, address(manager));
        (
            uint256 userInputBalanceBefore,
            uint256 userOutputBalanceBefore,
            uint256 userInputBalanceAfter,
            uint256 userOutputBalanceAfter
        ) = _finalizeAndExecuteSwap(CurrencyLibrary.ADDRESS_ZERO, wrappedCurrency1, amountIn);
        (, uint256 outputBalanceAfter, uint256 ethBalanceAfter) =
            getInputAndOutputBalancesPath(tokenPath, address(manager));

        // check intermediate token balances
        assertEq(intermediateBalanceBefore, currency0.balanceOfSelf());
        assertEq(userInputBalanceBefore - userInputBalanceAfter, amountIn);
        assertEq(userOutputBalanceAfter - userOutputBalanceBefore, expectedAmountOut);
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
            _getExactInputParamsWithHook(tokenPath, amountIn, address(permissionedHooks));

        plan = plan.add(Actions.SWAP_EXACT_IN, abi.encode(params));

        uint256 intermediateBalanceBefore = currency0.balanceOfSelf();

        (uint256 inputBalanceBefore,, uint256 ethBalanceBefore) =
            getInputAndOutputBalancesPath(tokenPath, address(manager));
        (
            uint256 userInputBalanceBefore,
            uint256 userOutputBalanceBefore,
            uint256 userInputBalanceAfter,
            uint256 userOutputBalanceAfter
        ) = _finalizeAndExecuteSwap(wrappedCurrency1, CurrencyLibrary.ADDRESS_ZERO, amountIn);
        (uint256 inputBalanceAfter,, uint256 ethBalanceAfter) =
            getInputAndOutputBalancesPath(tokenPath, address(manager));

        // check intermediate token balances
        assertEq(intermediateBalanceBefore, currency0.balanceOfSelf());
        assertEq(userInputBalanceBefore - userInputBalanceAfter, amountIn);
        assertEq(userOutputBalanceAfter - userOutputBalanceBefore, expectedAmountOut);
        assertEq(nativeKey.currency0.balanceOf(address(permissionedRouter)), 0);
        assertEq(nativeKey.currency1.balanceOf(address(permissionedRouter)), 0);
        assertEq(currency1.balanceOf(address(permissionedRouter)), 0);
        assertEq(ethBalanceAfter - ethBalanceBefore, expectedAmountOut);
        assertEq(inputBalanceAfter - inputBalanceBefore, amountIn);
    }

    function test_swap_nativeIn_settleRouterBalance_swapOpenDelta() public {
        uint256 amountIn = 1000;
        uint256 expectedAmountOut = 949;
        bool zeroForOne = true;

        vm.deal(address(permissionedRouter), amountIn);

        IV4Router.ExactInputSingleParams memory params =
            IV4Router.ExactInputSingleParams(nativeKey, zeroForOne, ActionConstants.OPEN_DELTA, 0, bytes(""));

        plan = plan.add(Actions.SETTLE, abi.encode(nativeKey.currency0, ActionConstants.CONTRACT_BALANCE, false));
        plan = plan.add(Actions.SWAP_EXACT_IN_SINGLE, abi.encode(params));
        plan = plan.add(Actions.TAKE_ALL, abi.encode(nativeKey.currency1, MIN_TAKE_AMOUNT));

        bytes memory data = plan.encode();

        (uint256 inputBalanceBefore, uint256 outputBalanceBefore, uint256 ethBalanceBefore) =
            getInputAndOutputBalances(nativeKey, zeroForOne, address(manager));
        permissionedRouter.execute(COMMAND_V4_SWAP, toBytesArray(data), type(uint256).max);
        (uint256 inputBalanceAfter, uint256 outputBalanceAfter, uint256 ethBalanceAfter) =
            getInputAndOutputBalances(nativeKey, zeroForOne, address(manager));

        // caller didnt pay, router paid, caller received the output
        assertEq(ethBalanceBefore, ethBalanceAfter);
        assertEq(inputBalanceAfter - inputBalanceBefore, amountIn);
        assertEq(outputBalanceBefore - outputBalanceAfter, expectedAmountOut);
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
        permissionedRouter.execute(COMMAND_V4_SWAP, toBytesArray(data), type(uint256).max);
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
        (
            uint256 userInputBalanceBefore,
            uint256 userOutputBalanceBefore,
            uint256 userInputBalanceAfter,
            uint256 userOutputBalanceAfter
        ) = _finalizeAndExecuteSwap(key0.currency0, key0.currency1, expectedAmountIn);
        (uint256 inputBalanceAfter, uint256 outputBalanceAfter,) =
            getInputAndOutputBalances(key0, zeroForOne, address(manager));

        assertEq(key0.currency0.balanceOf(address(permissionedRouter)), 0);
        assertEq(key0.currency1.balanceOf(address(permissionedRouter)), 0);
        assertEq(currency0.balanceOf(address(permissionedRouter)), 0);
        assertEq(currency1.balanceOf(address(permissionedRouter)), 0);
        assertEq(userInputBalanceBefore - userInputBalanceAfter, expectedAmountIn);
        assertEq(userOutputBalanceAfter - userOutputBalanceBefore, amountOut);
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
        (
            uint256 userInputBalanceBefore,
            uint256 userOutputBalanceBefore,
            uint256 userInputBalanceAfter,
            uint256 userOutputBalanceAfter
        ) = _finalizeAndExecuteSwap(key0.currency1, key0.currency0, expectedAmountIn);
        (uint256 inputBalanceAfter, uint256 outputBalanceAfter,) =
            getInputAndOutputBalances(key0, zeroForOne, address(manager));

        assertEq(wrappedCurrency0.balanceOf(address(permissionedRouter)), 0);
        assertEq(wrappedCurrency1.balanceOf(address(permissionedRouter)), 0);
        assertEq(userInputBalanceBefore - userInputBalanceAfter, expectedAmountIn);
        assertEq(userOutputBalanceAfter - userOutputBalanceBefore, amountOut);
        assertEq(outputBalanceBefore - outputBalanceAfter, amountOut);
        assertEq(inputBalanceAfter - inputBalanceBefore, expectedAmountIn);
    }

    function test_swapExactOut_revertsForAmountIn() public {
        uint256 amountOut = 1 ether;
        uint256 expectedAmountIn = 369070324262815812743748;

        tokenPath.push(wrappedCurrency0);
        tokenPath.push(wrappedCurrency1);

        IV4Router.ExactOutputParams memory params =
            _getExactOutputParamsWithHook(tokenPath, amountOut, address(permissionedHooks), expectedAmountIn);
        params.amountInMaximum = uint128(expectedAmountIn - 1);

        plan = plan.add(Actions.SWAP_EXACT_OUT, abi.encode(params));
        bytes memory data = plan.finalizeSwap(key0.currency0, key0.currency1, ActionConstants.MSG_SENDER);

        vm.expectRevert(
            abi.encodeWithSelector(IV4Router.V4TooMuchRequested.selector, expectedAmountIn - 1, expectedAmountIn)
        );
        permissionedRouter.execute(COMMAND_V4_SWAP, toBytesArray(data), type(uint256).max);
    }

    function test_swapExactOut_1Hop_zeroForOne() public {
        uint256 amountOut = 19992;
        uint256 expectedAmountIn = 434604409;

        tokenPath.push(wrappedCurrency1);
        tokenPath.push(wrappedCurrency0);

        IV4Router.ExactOutputParams memory params =
            _getExactOutputParamsWithHook(tokenPath, amountOut, address(permissionedHooks), expectedAmountIn);

        plan = plan.add(Actions.SWAP_EXACT_OUT, abi.encode(params));
        (uint256 inputBalanceBefore, uint256 outputBalanceBefore,) =
            getInputAndOutputBalancesPath(tokenPath, address(manager));
        (
            uint256 userInputBalanceBefore,
            uint256 userOutputBalanceBefore,
            uint256 userInputBalanceAfter,
            uint256 userOutputBalanceAfter
        ) = _finalizeAndExecuteSwap(key0.currency0, key0.currency1, expectedAmountIn);
        (uint256 inputBalanceAfter, uint256 outputBalanceAfter,) =
            getInputAndOutputBalancesPath(tokenPath, address(manager));

        assertEq(wrappedCurrency0.balanceOf(address(permissionedRouter)), 0);
        assertEq(wrappedCurrency1.balanceOf(address(permissionedRouter)), 0);
        assertEq(userInputBalanceBefore - userInputBalanceAfter, expectedAmountIn);
        assertEq(userOutputBalanceAfter - userOutputBalanceBefore, amountOut);
        assertEq(outputBalanceBefore - outputBalanceAfter, amountOut);
        assertEq(inputBalanceAfter - inputBalanceBefore, expectedAmountIn);
    }

    function test_swapExactOut_1Hop_oneForZero() public {
        uint256 amountOut = 19992;
        uint256 expectedAmountIn = 433302557;

        tokenPath.push(wrappedCurrency0);
        tokenPath.push(wrappedCurrency1);

        IV4Router.ExactOutputParams memory params =
            _getExactOutputParamsWithHook(tokenPath, amountOut, address(permissionedHooks), expectedAmountIn);

        plan = plan.add(Actions.SWAP_EXACT_OUT, abi.encode(params));
        (uint256 inputBalanceBefore, uint256 outputBalanceBefore,) =
            getInputAndOutputBalancesPath(tokenPath, address(manager));
        (
            uint256 userInputBalanceBefore,
            uint256 userOutputBalanceBefore,
            uint256 userInputBalanceAfter,
            uint256 userOutputBalanceAfter
        ) = _finalizeAndExecuteSwap(wrappedCurrency0, key0.currency0, expectedAmountIn);
        (uint256 inputBalanceAfter, uint256 outputBalanceAfter,) =
            getInputAndOutputBalancesPath(tokenPath, address(manager));

        assertEq(wrappedCurrency0.balanceOf(address(permissionedRouter)), 0);
        assertEq(wrappedCurrency1.balanceOf(address(permissionedRouter)), 0);
        assertEq(userInputBalanceBefore - userInputBalanceAfter, expectedAmountIn);
        assertEq(userOutputBalanceAfter - userOutputBalanceBefore, amountOut);
        assertEq(outputBalanceBefore - outputBalanceAfter, amountOut);
        assertEq(inputBalanceAfter - inputBalanceBefore, expectedAmountIn);
    }

    function test_swapExactOut_2Hops() public {
        uint256 amountOut = 100;
        uint256 expectedAmountIn = 104;

        tokenPath.push(wrappedCurrency0);
        tokenPath.push(wrappedCurrency1);
        tokenPath.push(currency2);

        IV4Router.ExactOutputParams memory params =
            _getExactOutputParamsWithHook(tokenPath, amountOut, address(permissionedHooks), expectedAmountIn);

        uint256 intermediateBalanceBefore = currency1.balanceOfSelf();

        plan = plan.add(Actions.SWAP_EXACT_OUT, abi.encode(params));
        (uint256 inputBalanceBefore, uint256 outputBalanceBefore,) =
            getInputAndOutputBalancesPath(tokenPath, address(manager));
        (
            uint256 userInputBalanceBefore,
            uint256 userOutputBalanceBefore,
            uint256 userInputBalanceAfter,
            uint256 userOutputBalanceAfter
        ) = _finalizeAndExecuteSwap(wrappedCurrency0, currency2, expectedAmountIn);
        (uint256 inputBalanceAfter, uint256 outputBalanceAfter,) =
            getInputAndOutputBalancesPath(tokenPath, address(manager));

        assertEq(intermediateBalanceBefore, currency1.balanceOfSelf());
        assertEq(wrappedCurrency0.balanceOf(address(permissionedRouter)), 0);
        assertEq(wrappedCurrency1.balanceOf(address(permissionedRouter)), 0);
        assertEq(currency2.balanceOf(address(permissionedRouter)), 0);
        assertEq(userInputBalanceBefore - userInputBalanceAfter, expectedAmountIn);
        assertEq(userOutputBalanceAfter - userOutputBalanceBefore, amountOut);
        assertEq(outputBalanceBefore - outputBalanceAfter, amountOut);
        assertEq(inputBalanceAfter - inputBalanceBefore, expectedAmountIn);
    }

    function test_swapExactOut_3Hops() public {
        uint256 amountOut = 100;
        uint256 expectedAmountIn = 106;

        tokenPath.push(wrappedCurrency0);
        tokenPath.push(wrappedCurrency1);
        tokenPath.push(currency2);
        tokenPath.push(currency3);

        IV4Router.ExactOutputParams memory params =
            _getExactOutputParamsWithHook(tokenPath, amountOut, address(permissionedHooks), expectedAmountIn);

        plan = plan.add(Actions.SWAP_EXACT_OUT, abi.encode(params));

        (uint256 inputBalanceBefore, uint256 outputBalanceBefore,) =
            getInputAndOutputBalancesPath(tokenPath, address(manager));
        (
            uint256 userInputBalanceBefore,
            uint256 userOutputBalanceBefore,
            uint256 userInputBalanceAfter,
            uint256 userOutputBalanceAfter
        ) = _finalizeAndExecuteSwap(key0.currency1, currency3, expectedAmountIn);
        (uint256 inputBalanceAfter, uint256 outputBalanceAfter,) =
            getInputAndOutputBalancesPath(tokenPath, address(manager));

        assertEq(wrappedCurrency0.balanceOf(address(permissionedRouter)), 0);
        assertEq(wrappedCurrency1.balanceOf(address(permissionedRouter)), 0);
        assertEq(currency2.balanceOf(address(permissionedRouter)), 0);
        assertEq(currency3.balanceOf(address(permissionedRouter)), 0);
        assertEq(userInputBalanceBefore - userInputBalanceAfter, expectedAmountIn);
        assertEq(userOutputBalanceAfter - userOutputBalanceBefore, amountOut);
        assertEq(outputBalanceBefore - outputBalanceAfter, amountOut);
        assertEq(inputBalanceAfter - inputBalanceBefore, expectedAmountIn);
    }

    function test_swapExactOut_3Hops_permissioned_middle() public {
        uint256 amountOut = 100;
        uint256 expectedAmountIn = 106;

        tokenPath.push(currency4);
        tokenPath.push(wrappedCurrency0);
        tokenPath.push(wrappedCurrency1);
        tokenPath.push(currency2);

        IV4Router.ExactOutputParams memory params =
            _getExactOutputParamsWithHook(tokenPath, amountOut, address(permissionedHooks), expectedAmountIn);

        plan = plan.add(Actions.SWAP_EXACT_OUT, abi.encode(params));

        (uint256 inputBalanceBefore, uint256 outputBalanceBefore,) =
            getInputAndOutputBalancesPath(tokenPath, address(manager));
        (
            uint256 userInputBalanceBefore,
            uint256 userOutputBalanceBefore,
            uint256 userInputBalanceAfter,
            uint256 userOutputBalanceAfter
        ) = _finalizeAndExecuteSwap(currency4, currency2, expectedAmountIn);
        (uint256 inputBalanceAfter, uint256 outputBalanceAfter,) =
            getInputAndOutputBalancesPath(tokenPath, address(manager));

        assertEq(currency4.balanceOf(address(permissionedRouter)), 0);
        assertEq(wrappedCurrency0.balanceOf(address(permissionedRouter)), 0);
        assertEq(wrappedCurrency1.balanceOf(address(permissionedRouter)), 0);
        assertEq(currency2.balanceOf(address(permissionedRouter)), 0);
        assertEq(userInputBalanceBefore - userInputBalanceAfter, expectedAmountIn);
        assertEq(userOutputBalanceAfter - userOutputBalanceBefore, amountOut);
        assertEq(outputBalanceBefore - outputBalanceAfter, amountOut);
        assertEq(inputBalanceAfter - inputBalanceBefore, expectedAmountIn);
    }

    function test_swapExactOut_3Hops_mmiddle_unauthorized_reverts() public {
        uint256 amountOut = 100;
        uint256 expectedAmountIn = 106;

        currency4.transfer(unauthorizedUser, 1000);

        tokenPath.push(currency4);
        tokenPath.push(wrappedCurrency0);
        tokenPath.push(wrappedCurrency1);
        tokenPath.push(currency2);

        MockPermissionedToken(Currency.unwrap(currency0)).setAllowlist(unauthorizedUser, PermissionFlags.NONE);
        MockPermissionedToken(Currency.unwrap(currency1)).setAllowlist(unauthorizedUser, PermissionFlags.NONE);

        IV4Router.ExactOutputParams memory params =
            _getExactOutputParamsWithHook(tokenPath, amountOut, address(permissionedHooks), expectedAmountIn);

        plan = plan.add(Actions.SWAP_EXACT_OUT, abi.encode(params));

        bytes memory data = plan.finalizeSwap(currency4, currency2, ActionConstants.MSG_SENDER);

        vm.prank(unauthorizedUser);
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(permissionedHooks),
                IHooks.beforeSwap.selector,
                abi.encodeWithSelector(Unauthorized.selector),
                abi.encodeWithSelector(HookCallFailed.selector)
            )
        );
        permissionedRouter.execute(COMMAND_V4_SWAP, toBytesArray(data), type(uint256).max);
    }

    function test_swapExactOut_native_3Hops_permissioned_middle() public {
        uint256 amountOut = 100;
        uint256 expectedAmountIn = 106;

        tokenPath.push(nativeKey.currency0);
        tokenPath.push(wrappedCurrency0);
        tokenPath.push(wrappedCurrency1);
        tokenPath.push(currency2);

        IV4Router.ExactOutputParams memory params =
            _getExactOutputParamsWithHook(tokenPath, amountOut, address(permissionedHooks), expectedAmountIn);

        plan = plan.add(Actions.SWAP_EXACT_OUT, abi.encode(params));

        (uint256 inputBalanceBefore, uint256 outputBalanceBefore,) =
            getInputAndOutputBalancesPath(tokenPath, address(manager));
        (
            uint256 userInputBalanceBefore,
            uint256 userOutputBalanceBefore,
            uint256 userInputBalanceAfter,
            uint256 userOutputBalanceAfter
        ) = _finalizeAndExecuteSwap(nativeKey.currency0, currency2, expectedAmountIn);
        (uint256 inputBalanceAfter, uint256 outputBalanceAfter,) =
            getInputAndOutputBalancesPath(tokenPath, address(manager));

        assertEq(nativeKey.currency0.balanceOf(address(permissionedRouter)), 0);
        assertEq(wrappedCurrency0.balanceOf(address(permissionedRouter)), 0);
        assertEq(wrappedCurrency1.balanceOf(address(permissionedRouter)), 0);
        assertEq(currency2.balanceOf(address(permissionedRouter)), 0);
        assertEq(userInputBalanceBefore - userInputBalanceAfter, expectedAmountIn);
        assertEq(userOutputBalanceAfter - userOutputBalanceBefore, amountOut);
        assertEq(outputBalanceBefore - outputBalanceAfter, amountOut);
        assertEq(inputBalanceAfter - inputBalanceBefore, expectedAmountIn);
    }

    function test_swapExactOut_native_3Hops_mmiddle_unauthorized_reverts() public {
        nativeKey.currency0.transfer(unauthorizedUser, 1000);

        uint256 amountOut = 100;
        uint256 expectedAmountIn = 106;

        tokenPath.push(nativeKey.currency0);
        tokenPath.push(wrappedCurrency0);
        tokenPath.push(wrappedCurrency1);
        tokenPath.push(currency2);

        MockPermissionedToken(Currency.unwrap(currency0)).setAllowlist(unauthorizedUser, PermissionFlags.NONE);
        MockPermissionedToken(Currency.unwrap(currency1)).setAllowlist(unauthorizedUser, PermissionFlags.NONE);

        IV4Router.ExactOutputParams memory params =
            _getExactOutputParamsWithHook(tokenPath, amountOut, address(permissionedHooks), expectedAmountIn);

        plan = plan.add(Actions.SWAP_EXACT_OUT, abi.encode(params));

        bytes memory data = plan.finalizeSwap(nativeKey.currency0, currency2, ActionConstants.MSG_SENDER);

        vm.prank(unauthorizedUser);
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(permissionedHooks),
                IHooks.beforeSwap.selector,
                abi.encodeWithSelector(Unauthorized.selector),
                abi.encodeWithSelector(HookCallFailed.selector)
            )
        );
        permissionedRouter.execute{value: (nativeKey.currency0.isAddressZero()) ? expectedAmountIn : 0}(COMMAND_V4_SWAP, toBytesArray(data), type(uint256).max);
    }

    function test_swapExactOutputSingle_swapOpenDelta() public {
        uint256 expectedAmountIn = 946;
        uint256 expectedOutput = 900;

        IV4Router.ExactOutputSingleParams memory params = IV4Router.ExactOutputSingleParams(
            key0, true, ActionConstants.OPEN_DELTA, uint128(expectedAmountIn), bytes("")
        );

        plan = plan.add(Actions.TAKE, abi.encode(key0.currency1, ActionConstants.ADDRESS_THIS, expectedOutput));
        plan = plan.add(Actions.SWAP_EXACT_OUT_SINGLE, abi.encode(params));
        plan = plan.add(Actions.SETTLE, abi.encode(key0.currency0, ActionConstants.OPEN_DELTA, true));

        bytes memory data = plan.encode();

        (uint256 inputBalanceBefore, uint256 outputBalanceBefore,) =
            getInputAndOutputBalances(key0, true, address(manager));
        permissionedRouter.execute(COMMAND_V4_SWAP, toBytesArray(data), type(uint256).max);
        (uint256 inputBalanceAfter, uint256 outputBalanceAfter,) =
            getInputAndOutputBalances(key0, true, address(manager));

        assertEq(inputBalanceAfter - inputBalanceBefore, expectedAmountIn);
        assertEq(outputBalanceBefore - outputBalanceAfter, expectedOutput);
    }

    function test_swapExactOut_swapOpenDelta() public {
        uint256 expectedAmountIn = 1057;
        uint256 expectedOutput = 1000;

        tokenPath.push(wrappedCurrency1);
        tokenPath.push(wrappedCurrency0);

        IV4Router.ExactOutputParams memory params = _getExactOutputParamsWithHook(
            tokenPath, ActionConstants.OPEN_DELTA, address(permissionedHooks), expectedAmountIn
        );

        plan = plan.add(Actions.TAKE, abi.encode(key0.currency1, ActionConstants.ADDRESS_THIS, expectedOutput));
        plan = plan.add(Actions.SWAP_EXACT_OUT, abi.encode(params));
        plan = plan.add(Actions.SETTLE, abi.encode(key0.currency0, ActionConstants.OPEN_DELTA, true));

        bytes memory data = plan.encode();

        (uint256 inputBalanceBefore, uint256 outputBalanceBefore,) =
            getInputAndOutputBalancesPath(tokenPath, address(manager));
        permissionedRouter.execute(COMMAND_V4_SWAP, toBytesArray(data), type(uint256).max);
        (uint256 inputBalanceAfter, uint256 outputBalanceAfter,) =
            getInputAndOutputBalancesPath(tokenPath, address(manager));

        assertEq(inputBalanceAfter - inputBalanceBefore, expectedAmountIn);
        assertEq(outputBalanceBefore - outputBalanceAfter, expectedOutput);
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
        (
            uint256 userInputBalanceBefore,
            uint256 userOutputBalanceBefore,
            uint256 userInputBalanceAfter,
            uint256 userOutputBalanceAfter
        ) = _finalizeAndExecuteSwap(nativeKey.currency1, nativeKey.currency0, expectedAmountIn);
        (uint256 inputBalanceAfter,, uint256 ethBalanceAfter) =
            getInputAndOutputBalances(nativeKey, zeroForOne, address(manager));

        assertEq(nativeKey.currency0.balanceOf(address(permissionedRouter)), 0);
        assertEq(nativeKey.currency1.balanceOf(address(permissionedRouter)), 0);
        assertEq(userInputBalanceBefore - userInputBalanceAfter, expectedAmountIn);
        assertEq(userOutputBalanceAfter - userOutputBalanceBefore, amountOut);
        assertEq(ethBalanceAfter - ethBalanceBefore, amountOut);
        assertEq(inputBalanceAfter - inputBalanceBefore, expectedAmountIn);
    }

    function test_nativeOut_swapExactOut_1Hop() public {
        uint256 amountOut = 19992;
        uint256 expectedAmountIn = 433302557;

        tokenPath.push(nativeKey.currency1);
        tokenPath.push(CurrencyLibrary.ADDRESS_ZERO);

        IV4Router.ExactOutputParams memory params =
            _getExactOutputParamsWithHook(tokenPath, amountOut, address(permissionedHooks), expectedAmountIn);

        plan = plan.add(Actions.SWAP_EXACT_OUT, abi.encode(params));
        (uint256 inputBalanceBefore,, uint256 ethBalanceBefore) =
            getInputAndOutputBalancesPath(tokenPath, address(manager));
        (
            uint256 userInputBalanceBefore,
            uint256 userOutputBalanceBefore,
            uint256 userInputBalanceAfter,
            uint256 userOutputBalanceAfter
        ) = _finalizeAndExecuteSwap(nativeKey.currency1, CurrencyLibrary.ADDRESS_ZERO, expectedAmountIn);
        (uint256 inputBalanceAfter,, uint256 ethBalanceAfter) =
            getInputAndOutputBalancesPath(tokenPath, address(manager));

        assertEq(nativeKey.currency0.balanceOf(address(permissionedRouter)), 0);
        assertEq(nativeKey.currency1.balanceOf(address(permissionedRouter)), 0);
        assertEq(userInputBalanceBefore - userInputBalanceAfter, expectedAmountIn);
        assertEq(userOutputBalanceAfter - userOutputBalanceBefore, amountOut);
        assertEq(ethBalanceAfter - ethBalanceBefore, amountOut);
        assertEq(inputBalanceAfter - inputBalanceBefore, expectedAmountIn);
    }

    /*//////////////////////////////////////////////////////////////
                ROUTER SELF-PAYMENT COVERAGE TEST
    //////////////////////////////////////////////////////////////*/

    function test_router_self_payment() public {
        uint256 amountIn = 100000;

        IERC20(Currency.unwrap(key2.currency0)).transfer(address(permissionedRouter), amountIn);

        IV4Router.ExactInputSingleParams memory params =
            IV4Router.ExactInputSingleParams(key2, true, uint128(amountIn), 0, bytes(""));

        plan = plan.add(Actions.SETTLE, abi.encode(key2.currency0, ActionConstants.CONTRACT_BALANCE, false));
        plan = plan.add(Actions.SWAP_EXACT_IN_SINGLE, abi.encode(params));
        plan = plan.add(Actions.TAKE_ALL, abi.encode(key2.currency1, 0));

        bytes memory data = plan.encode();

        (uint256 inputBalanceBefore, uint256 outputBalanceBefore,) =
            getInputAndOutputBalances(key2, true, address(manager));

        // Execute the swap - this should trigger the _pay function with payer == address(this) and permissionedToken == address(0)
        permissionedRouter.execute(COMMAND_V4_SWAP, toBytesArray(data), type(uint256).max);

        (uint256 inputBalanceAfter, uint256 outputBalanceAfter,) =
            getInputAndOutputBalances(key2, true, address(manager));

        // Verify the router's balance was used (it should be 0 after the swap)
        assertEq(key2.currency0.balanceOf(address(permissionedRouter)), 0);
        assertEq(inputBalanceAfter - inputBalanceBefore, amountIn);
        assertGt(outputBalanceBefore - outputBalanceAfter, 0);
    }

    function test_router_self_payment_permissioned_token() public {
        uint256 amountIn = 100000;

        IERC20(Currency.unwrap(getPermissionedCurrency(key0.currency0))).transfer(address(permissionedRouter), amountIn);

        IV4Router.ExactInputSingleParams memory params =
            IV4Router.ExactInputSingleParams(key0, true, uint128(amountIn), 0, bytes(""));

        plan = plan.add(Actions.SETTLE, abi.encode((key0.currency0), ActionConstants.CONTRACT_BALANCE, false));
        plan = plan.add(Actions.SWAP_EXACT_IN_SINGLE, abi.encode(params));
        plan = plan.add(Actions.TAKE_ALL, abi.encode((key0.currency1), 0));

        bytes memory data = plan.encode();

        (uint256 inputBalanceBefore, uint256 outputBalanceBefore,) =
            getInputAndOutputBalances(key0, true, address(manager));

        // Execute the swap - this should trigger the _pay function with payer == address(this) and permissionedToken != address(0)
        permissionedRouter.execute(COMMAND_V4_SWAP, toBytesArray(data), type(uint256).max);

        (uint256 inputBalanceAfter, uint256 outputBalanceAfter,) =
            getInputAndOutputBalances(key0, true, address(manager));

        // Verify the router's balance was used (it should be 0 after the swap)
        assertEq(getPermissionedCurrency(key0.currency0).balanceOf(address(permissionedRouter)), 0);
        assertEq(inputBalanceAfter - inputBalanceBefore, amountIn);
        assertGt(outputBalanceBefore - outputBalanceAfter, 0);
    }

    function test_router_self_payment_permissioned_token_unauthorized_reverts() public {
        uint256 amountIn = 100000;

        MockPermissionedToken(Currency.unwrap(getPermissionedCurrency(key0.currency0))).setAllowlist(
            unauthorizedUser, PermissionFlags.ALL_ALLOWED
        );
        IERC20(Currency.unwrap(getPermissionedCurrency(key0.currency0))).transfer(address(unauthorizedUser), amountIn);

        vm.prank(unauthorizedUser);
        IERC20(Currency.unwrap(getPermissionedCurrency(key0.currency0))).transfer(address(permissionedRouter), amountIn);

        MockPermissionedToken(Currency.unwrap(getPermissionedCurrency(key0.currency0))).setAllowlist(
            unauthorizedUser, PermissionFlags.NONE
        );

        IV4Router.ExactInputSingleParams memory params =
            IV4Router.ExactInputSingleParams(key0, true, uint128(amountIn), 0, bytes(""));

        plan = plan.add(Actions.SETTLE, abi.encode((key0.currency0), ActionConstants.CONTRACT_BALANCE, false));
        plan = plan.add(Actions.SWAP_EXACT_IN_SINGLE, abi.encode(params));
        plan = plan.add(Actions.TAKE_ALL, abi.encode((key0.currency1), 0));

        bytes memory data = plan.encode();

        vm.prank(unauthorizedUser);
        vm.expectRevert(Unauthorized.selector);
        permissionedRouter.execute(COMMAND_V4_SWAP, toBytesArray(data), type(uint256).max);
    }

    function test_command_permit2_permit() public {
        IAllowanceTransfer.PermitSingle memory permitSingle = IAllowanceTransfer.PermitSingle({
            details: IAllowanceTransfer.PermitDetails({
                token: Currency.unwrap(currency0),
                amount: 1e18,
                expiration: uint48(block.timestamp + 3600),
                nonce: 0
            }),
            spender: address(permissionedRouter),
            sigDeadline: block.timestamp + 3600
        });

        uint256 testKey = uint256(0x22);
        address testSigner = vm.addr(testKey);

        bytes32 digest = generatePermitDigest(permitSingle);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(testKey, digest);
        bytes memory signature = abi.encodePacked(r, s, v);
        bytes memory data = abi.encode(permitSingle, signature);

        vm.prank(testSigner);
        permissionedRouter.execute(COMMAND_PERMIT2_PERMIT, toBytesArray(data), type(uint256).max);
    }

    function test_invalid_command_reverts() public {
        bytes memory data = hex"1234567890";
        vm.expectRevert(CommandNotImplemented.selector);
        permissionedRouter.execute(hex"07", toBytesArray(data), type(uint256).max);
    }

    function test_failed_call_reverts() public {
        IAllowanceTransfer.PermitSingle memory permitSingle = IAllowanceTransfer.PermitSingle({
            details: IAllowanceTransfer.PermitDetails({
                token: Currency.unwrap(currency0),
                amount: 1e18,
                expiration: uint48(block.timestamp + 3600),
                nonce: 0
            }),
            spender: address(permissionedRouter),
            sigDeadline: block.timestamp + 3600
        });
        uint256 testKey = uint256(0x22);

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(testKey, hex"aa");
        bytes memory signature = abi.encodePacked(r, s, v);
        bytes memory data = abi.encode(permitSingle, signature);

        vm.expectRevert(abi.encodeWithSelector(ExecutionFailed.selector, 0, hex""));
        permissionedRouter.execute(COMMAND_PERMIT2_PERMIT, toBytesArray(data), type(uint256).max);
    }

    function test_slice_out_of_bounds_reverts() public {
        bytes memory data = hex"1234567890";
        vm.expectRevert(SliceOutOfBounds.selector);
        permissionedRouter.execute(COMMAND_PERMIT2_PERMIT, toBytesArray(data), type(uint256).max);
    }

    function test_hooks() public {
        SwapParams memory swapParams = SwapParams({zeroForOne: true, amountSpecified: 100000, sqrtPriceLimitX96: 0});
        ModifyLiquidityParams memory modifyLiquidityParams =
            ModifyLiquidityParams({tickLower: 0, tickUpper: 0, liquidityDelta: 0, salt: bytes32(0)});
        BalanceDelta balanceDelta = BalanceDelta.wrap(0);

        // Use manager to avoid NotPoolManager errors for hooks with OnlyPoolManager modifier
        vm.startPrank(address(manager));
        vm.expectRevert(HookNotImplemented.selector);
        permissionedHooks.afterSwap(address(this), key0, swapParams, balanceDelta, bytes(""));
        vm.expectRevert(HookNotImplemented.selector);
        permissionedHooks.beforeInitialize(address(this), key0, 0);
        vm.expectRevert(HookNotImplemented.selector);
        permissionedHooks.afterInitialize(address(this), key0, 0, 0);
        vm.expectRevert(HookNotImplemented.selector);
        permissionedHooks.beforeRemoveLiquidity(address(this), key0, modifyLiquidityParams, bytes(""));
        vm.expectRevert(HookNotImplemented.selector);
        permissionedHooks.afterRemoveLiquidity(
            address(this), key0, modifyLiquidityParams, balanceDelta, balanceDelta, bytes("")
        );
        vm.expectRevert(HookNotImplemented.selector);
        permissionedHooks.afterAddLiquidity(
            address(this), key0, modifyLiquidityParams, balanceDelta, balanceDelta, bytes("")
        );
        vm.expectRevert(HookNotImplemented.selector);
        permissionedHooks.beforeDonate(address(this), key0, 0, 0, bytes(""));
        vm.expectRevert(HookNotImplemented.selector);
        permissionedHooks.afterDonate(address(this), key0, 0, 0, bytes(""));
    }

    /*//////////////////////////////////////////////////////////////
                RECEIVE FALLBACK TESTS
    //////////////////////////////////////////////////////////////*/

    error InvalidEthSender();

    function test_receive_fallback_reverts() public {
        (bool success, bytes memory data) = address(permissionedRouter).call{value: 1 ether}("");

        assertEq(success, false);
        assertEq(bytes4(data), InvalidEthSender.selector);
    }

    function test_receive_fallback_from_posm() public {
        vm.deal(address(manager), 1 ether);

        vm.prank(address(manager));
        (bool success,) = address(permissionedRouter).call{value: 1 ether}("");
        assertEq(success, true);
    }

    function test_receive_fallback_from_weth() public {
        vm.deal(address(permissionedRouter), 1 ether);

        vm.startPrank(address(permissionedRouter));
        weth9.deposit{value: 1 ether}();
        weth9.approve(address(permissionedRouter), 1 ether);
        weth9.withdraw(1 ether);
        vm.stopPrank();
    }

    receive() external payable {}
    fallback() external {}
}
