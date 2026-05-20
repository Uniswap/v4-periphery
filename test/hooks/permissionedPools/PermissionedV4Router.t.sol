// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {VmSafe} from "forge-std/Vm.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {Hooks, IHooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {PermitHash} from "permit2/src/libraries/PermitHash.sol";
import {IV4Router} from "../../../src/interfaces/IV4Router.sol";
import {PermissionedRoutingTestHelpers} from "./shared/PermissionedRoutingTestHelpers.sol";
import {Planner} from "../../shared/Planner.sol";
import {Actions} from "../../../src/libraries/Actions.sol";
import {ActionConstants} from "../../../src/libraries/ActionConstants.sol";
import {MockPermissionedToken, MockAllowlistChecker} from "./PermissionedPoolsBase.sol";
import {MockPermissionedHooks} from "./mocks/MockPermissionedHooks.sol";
import {PermissionFlags, PermissionFlag} from "../../../src/hooks/permissionedPools/libraries/PermissionFlags.sol";
import {PathKey} from "../../../src/libraries/PathKey.sol";

contract PermissionedV4RouterTest is PermissionedRoutingTestHelpers {
    using PermitHash for IAllowanceTransfer.PermitSingle;
    using StateLibrary for IPoolManager;

    // To allow testing without importing PermissionedV4Router
    error HookNotImplemented();
    error Unauthorized();
    error HookCallFailed();
    error SliceOutOfBounds();
    error NoVerifiedAdapter();
    error UnverifiedAdapter();
    error InvalidCommandType(uint256 commandType);
    error ExecutionFailed(uint256 commandIndex, bytes output);

    Currency public permissionsAdapter0Currency;
    Currency public permissionsAdapter1Currency;

    // Test Users
    address public alice = makeAddr("ALICE");
    address public unauthorizedUser = makeAddr("UNAUTHORIZED");

    // Commands
    bytes public COMMAND_V4_SWAP = hex"10";
    bytes public COMMAND_PERMIT2_PERMIT = hex"0a";

    function setUp() public {
        setupPermissionedRouterCurrenciesAndPoolsWithLiquidity(alice);

        permissionsAdapter0Currency = Currency.wrap(address(permissionsAdapter0));
        permissionsAdapter1Currency = Currency.wrap(address(permissionsAdapter1));
        permissionsAdapter0.updateSwappingEnabled(true);
        permissionsAdapter1.updateSwappingEnabled(true);

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
        PoolKey memory adapterKey =
            PoolKey(permissionsAdapter1Currency, permissionsAdapter0Currency, 3000, 60, permissionedHooks);

        IV4Router.ExactInputSingleParams memory params =
            IV4Router.ExactInputSingleParams(adapterKey, true, uint128(amountIn), 0, 0, bytes(""));

        plan = plan.add(Actions.SWAP_EXACT_IN_SINGLE, abi.encode(params));
        bytes memory data =
            plan.finalizeSwap(permissionsAdapter1Currency, permissionsAdapter0Currency, ActionConstants.MSG_SENDER);

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

        Currency currencyA = permissionsAdapter0Currency;
        Currency currencyB = permissionsAdapter1Currency;
        if (Currency.unwrap(currencyA) > Currency.unwrap(currencyB)) (currencyA, currencyB) = (currencyB, currencyA);

        uint256 amountIn = 1 ether;
        PoolKey memory adapterKey = PoolKey(currencyA, currencyB, 3000, 60, permissionedHooks);

        IV4Router.ExactInputSingleParams memory params =
            IV4Router.ExactInputSingleParams(adapterKey, true, uint128(amountIn), 0, 0, bytes(""));

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

    error SwappingDisabled();

    function test_swap_revert_trading_disabled() public {
        IERC20(Currency.unwrap(currency0)).transfer(alice, 2 ether);
        IERC20(Currency.unwrap(currency1)).transfer(alice, 2 ether);

        uint256 amountIn = 100;
        PoolKey memory adapterKey =
            PoolKey(permissionsAdapter1Currency, permissionsAdapter0Currency, 3000, 60, permissionedHooks);

        IV4Router.ExactInputSingleParams memory params =
            IV4Router.ExactInputSingleParams(adapterKey, true, uint128(amountIn), 0, 0, bytes(""));

        plan = plan.add(Actions.SWAP_EXACT_IN_SINGLE, abi.encode(params));
        bytes memory data =
            plan.finalizeSwap(permissionsAdapter1Currency, permissionsAdapter0Currency, ActionConstants.MSG_SENDER);

        permissionsAdapter0.updateSwappingEnabled(false);

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(permissionedHooks),
                IHooks.beforeSwap.selector,
                abi.encodeWithSelector(SwappingDisabled.selector),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        permissionedRouter.execute(COMMAND_V4_SWAP, toBytesArray(data), type(uint256).max);

        permissionsAdapter0.updateSwappingEnabled(true);
        permissionsAdapter1.updateSwappingEnabled(false);

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(permissionedHooks),
                IHooks.beforeSwap.selector,
                abi.encodeWithSelector(SwappingDisabled.selector),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        permissionedRouter.execute(COMMAND_V4_SWAP, toBytesArray(data), type(uint256).max);
    }

    /// @notice Standalone SETTLE+TAKE bypasses the hook's swap pause. Router-side check must catch it.
    function test_settle_revert_when_swapping_disabled_on_input_adapter() public {
        IERC20(Currency.unwrap(currency0)).transfer(alice, 2 ether);
        IERC20(Currency.unwrap(currency1)).transfer(alice, 2 ether);

        plan = plan.add(Actions.SETTLE, abi.encode(permissionsAdapter0Currency, uint256(100), true));
        plan = plan.add(Actions.TAKE, abi.encode(permissionsAdapter0Currency, alice, uint256(100)));
        bytes memory data = plan.encode();

        permissionsAdapter0.updateSwappingEnabled(false);

        vm.prank(alice);
        vm.expectRevert(SwappingDisabled.selector);
        permissionedRouter.execute(COMMAND_V4_SWAP, toBytesArray(data), type(uint256).max);
    }

    function test_swap_succeeds_authorized_user() public {
        IERC20(Currency.unwrap(currency0)).transfer(alice, 2 ether);
        IERC20(Currency.unwrap(currency1)).transfer(alice, 2 ether);

        uint256 amountIn = 100;
        PoolKey memory adapterKey =
            PoolKey(permissionsAdapter1Currency, permissionsAdapter0Currency, 3000, 60, permissionedHooks);

        IV4Router.ExactInputSingleParams memory params =
            IV4Router.ExactInputSingleParams(adapterKey, true, uint128(amountIn), 0, 0, bytes(""));

        plan = plan.add(Actions.SWAP_EXACT_IN_SINGLE, abi.encode(params));
        bytes memory data =
            plan.finalizeSwap(permissionsAdapter1Currency, permissionsAdapter0Currency, ActionConstants.MSG_SENDER);

        vm.prank(alice);
        permissionedRouter.execute(COMMAND_V4_SWAP, toBytesArray(data), type(uint256).max);
    }

    function test_swap_authorized_router() public {
        IERC20(Currency.unwrap(currency0)).transfer(alice, 2 ether);
        IERC20(Currency.unwrap(currency1)).transfer(alice, 2 ether);

        uint256 amountIn = 100;
        uint256 expectedAmountOut = 98;
        PoolKey memory adapterKey =
            PoolKey(permissionsAdapter1Currency, permissionsAdapter0Currency, 3000, 60, permissionedHooks);

        IV4Router.ExactInputSingleParams memory params =
            IV4Router.ExactInputSingleParams(adapterKey, true, uint128(amountIn), 0, 0, bytes(""));

        plan = plan.add(Actions.SWAP_EXACT_IN_SINGLE, abi.encode(params));
        bytes memory data =
            plan.finalizeSwap(permissionsAdapter1Currency, permissionsAdapter0Currency, ActionConstants.MSG_SENDER);

        (uint256 inputBalanceBefore, uint256 outputBalanceBefore,) =
            getInputAndOutputBalances(adapterKey, true, address(manager));
        vm.prank(alice);
        permissionedRouter.execute(COMMAND_V4_SWAP, toBytesArray(data), type(uint256).max);
        (uint256 inputBalanceAfter, uint256 outputBalanceAfter,) =
            getInputAndOutputBalances(adapterKey, true, address(manager));

        assertEq(inputBalanceAfter - inputBalanceBefore, amountIn);
        assertEq(outputBalanceBefore - outputBalanceAfter, expectedAmountOut);
    }

    function test_swap_unauthorized_router_reverts() public {
        IERC20(Currency.unwrap(currency0)).transfer(alice, 2 ether);
        IERC20(Currency.unwrap(currency1)).transfer(alice, 2 ether);

        uint256 amountIn = 100;
        PoolKey memory adapterKey =
            PoolKey(permissionsAdapter1Currency, permissionsAdapter0Currency, 3000, 60, permissionedHooks);

        IV4Router.ExactInputSingleParams memory params =
            IV4Router.ExactInputSingleParams(adapterKey, true, uint128(amountIn), 0, 0, bytes(""));

        plan = plan.add(Actions.SWAP_EXACT_IN_SINGLE, abi.encode(params));
        bytes memory data =
            plan.finalizeSwap(permissionsAdapter1Currency, permissionsAdapter0Currency, ActionConstants.MSG_SENDER);

        permissionsAdapter0.updateAllowedWrapper(address(permissionedRouter), false);
        permissionsAdapter1.updateAllowedWrapper(address(permissionedRouter), false);

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
        bool zeroToOne = permissionsAdapter1Currency == key1.currency0;
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
            IV4Router.ExactInputSingleParams(key1, zeroToOne, uint128(amountIn), 0, 0, bytes(""));

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
        bool zeroToOne = !(permissionsAdapter1Currency == key1.currency0);
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
            IV4Router.ExactInputSingleParams(key1, zeroToOne, uint128(amountIn), 0, 0, bytes(""));

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
        bool zeroToOne = permissionsAdapter1Currency == key1.currency0;
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
            IV4Router.ExactInputSingleParams(key1, zeroToOne, uint128(amountIn), 0, 0, bytes(""));

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
        bool zeroToOne = !(permissionsAdapter1Currency == key1.currency0);
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
            IV4Router.ExactInputSingleParams(key1, zeroToOne, uint128(amountIn), 0, 0, bytes(""));

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
        PoolKey memory adapterKey =
            PoolKey(permissionsAdapter1Currency, permissionsAdapter0Currency, 3000, 60, permissionedHooks);

        IV4Router.ExactInputSingleParams memory params =
            IV4Router.ExactInputSingleParams(adapterKey, true, uint128(amountIn), 0, 0, bytes(""));

        plan = plan.add(Actions.SWAP_EXACT_IN_SINGLE, abi.encode(params));
        bytes memory data =
            plan.finalizeSwap(permissionsAdapter1Currency, permissionsAdapter0Currency, ActionConstants.MSG_SENDER);

        vm.prank(alice);
        vm.expectRevert();
        permissionedRouter.execute(COMMAND_V4_SWAP, toBytesArray(data), type(uint256).max);
    }

    function test_router_user_payment_permissioned_token_unauthorized_reverts() public {
        // Test that LIQUIDITY_ALLOWED does not allow swap operations
        MockPermissionedToken(Currency.unwrap(currency0)).setAllowlist(alice, PermissionFlags.LIQUIDITY_ALLOWED);
        MockPermissionedToken(Currency.unwrap(currency1)).setAllowlist(alice, PermissionFlags.LIQUIDITY_ALLOWED);

        IERC20(Currency.unwrap(currency0)).transfer(alice, 2 ether);
        IERC20(Currency.unwrap(currency1)).transfer(alice, 2 ether);

        uint256 amountIn = 100;
        PoolKey memory adapterKey =
            PoolKey(permissionsAdapter1Currency, permissionsAdapter0Currency, 3000, 60, insecureHooks);

        IV4Router.ExactInputSingleParams memory params =
            IV4Router.ExactInputSingleParams(adapterKey, true, uint128(amountIn), 0, 0, bytes(""));

        plan = plan.add(Actions.SWAP_EXACT_IN_SINGLE, abi.encode(params));
        bytes memory data =
            plan.finalizeSwap(permissionsAdapter1Currency, permissionsAdapter0Currency, ActionConstants.MSG_SENDER);

        vm.startPrank(alice);
        vm.expectRevert(Unauthorized.selector);
        permissionedRouter.execute(COMMAND_V4_SWAP, toBytesArray(data), type(uint256).max);
        vm.stopPrank();
    }

    function test_permission_flag_liquidity_allowed_swap_reverts() public {
        // Test that LIQUIDITY_ALLOWED does not allow swap operations
        MockPermissionedToken(Currency.unwrap(currency0)).setAllowlist(alice, PermissionFlags.LIQUIDITY_ALLOWED);
        MockPermissionedToken(Currency.unwrap(currency1)).setAllowlist(alice, PermissionFlags.LIQUIDITY_ALLOWED);

        IERC20(Currency.unwrap(currency0)).transfer(alice, 2 ether);
        IERC20(Currency.unwrap(currency1)).transfer(alice, 2 ether);

        uint256 amountIn = 100;
        PoolKey memory adapterKey =
            PoolKey(permissionsAdapter1Currency, permissionsAdapter0Currency, 3000, 60, permissionedHooks);

        IV4Router.ExactInputSingleParams memory params =
            IV4Router.ExactInputSingleParams(adapterKey, true, uint128(amountIn), 0, 0, bytes(""));

        plan = plan.add(Actions.SWAP_EXACT_IN_SINGLE, abi.encode(params));
        bytes memory data =
            plan.finalizeSwap(permissionsAdapter1Currency, permissionsAdapter0Currency, ActionConstants.MSG_SENDER);

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
        PoolKey memory adapterKey =
            PoolKey(permissionsAdapter1Currency, permissionsAdapter0Currency, 3000, 60, permissionedHooks);

        IV4Router.ExactInputSingleParams memory params =
            IV4Router.ExactInputSingleParams(adapterKey, true, uint128(amountIn), 0, 0, bytes(""));

        plan = plan.add(Actions.SWAP_EXACT_IN_SINGLE, abi.encode(params));
        bytes memory data =
            plan.finalizeSwap(permissionsAdapter1Currency, permissionsAdapter0Currency, ActionConstants.MSG_SENDER);

        vm.prank(alice);
        permissionedRouter.execute(COMMAND_V4_SWAP, toBytesArray(data), type(uint256).max);
    }

    function test_permission_flag_combinations_swap() public {
        // Test various combinations of permissions for swaps
        IERC20(Currency.unwrap(currency0)).transfer(alice, 2 ether);
        IERC20(Currency.unwrap(currency1)).transfer(alice, 2 ether);

        uint256 amountIn = 100;
        PoolKey memory adapterKey =
            PoolKey(permissionsAdapter1Currency, permissionsAdapter0Currency, 3000, 60, permissionedHooks);

        IV4Router.ExactInputSingleParams memory params =
            IV4Router.ExactInputSingleParams(adapterKey, true, uint128(amountIn), 0, 0, bytes(""));

        plan = plan.add(Actions.SWAP_EXACT_IN_SINGLE, abi.encode(params));
        bytes memory data =
            plan.finalizeSwap(permissionsAdapter1Currency, permissionsAdapter0Currency, ActionConstants.MSG_SENDER);

        // Test SWAP_ALLOWED + LIQUIDITY_ALLOWED (should work like ALL_ALLOWED)
        MockPermissionedToken(Currency.unwrap(currency0))
            .setAllowlist(alice, (PermissionFlags.SWAP_ALLOWED | PermissionFlags.LIQUIDITY_ALLOWED));
        MockPermissionedToken(Currency.unwrap(currency1))
            .setAllowlist(alice, (PermissionFlags.SWAP_ALLOWED | PermissionFlags.LIQUIDITY_ALLOWED));

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
        PoolKey memory adapterKey =
            PoolKey(permissionsAdapter1Currency, permissionsAdapter0Currency, 3000, 60, permissionedHooks);

        IV4Router.ExactInputSingleParams memory params =
            IV4Router.ExactInputSingleParams(adapterKey, true, uint128(amountIn), 0, 0, bytes(""));

        plan = plan.add(Actions.SWAP_EXACT_IN_SINGLE, abi.encode(params));
        bytes memory data =
            plan.finalizeSwap(permissionsAdapter1Currency, permissionsAdapter0Currency, ActionConstants.MSG_SENDER);

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
        PoolKey memory adapterKey =
            PoolKey(permissionsAdapter1Currency, permissionsAdapter0Currency, 3000, 60, permissionedHooks);

        IV4Router.ExactInputSingleParams memory params =
            IV4Router.ExactInputSingleParams(adapterKey, true, uint128(amountIn), 0, 0, bytes(""));

        plan = plan.add(Actions.SWAP_EXACT_IN_SINGLE, abi.encode(params));
        bytes memory data =
            plan.finalizeSwap(permissionsAdapter1Currency, permissionsAdapter0Currency, ActionConstants.MSG_SENDER);

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
        PoolKey memory adapterKey =
            PoolKey(permissionsAdapter1Currency, permissionsAdapter0Currency, 3000, 60, permissionedHooks);

        IV4Router.ExactInputSingleParams memory params =
            IV4Router.ExactInputSingleParams(adapterKey, true, uint128(amountIn), 0, 0, bytes(""));

        plan = plan.add(Actions.SWAP_EXACT_IN_SINGLE, abi.encode(params));
        bytes memory data =
            plan.finalizeSwap(permissionsAdapter1Currency, permissionsAdapter0Currency, ActionConstants.MSG_SENDER);

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
        MockPermissionedToken(Currency.unwrap(getPermissionedCurrency(permissionsAdapter0Currency)))
            .setAllowlist(alice, PermissionFlags.SWAP_ALLOWED);
        MockPermissionedToken(Currency.unwrap(getPermissionedCurrency(permissionsAdapter1Currency)))
            .setAllowlist(alice, PermissionFlags.SWAP_ALLOWED);

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
            IV4Router.ExactInputSingleParams(poolKey, true, uint128(amountIn), 0, 0, bytes(""));
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
        PoolKey memory adapterKey =
            PoolKey(permissionsAdapter1Currency, permissionsAdapter0Currency, 3000, 60, permissionedHooks);

        IV4Router.ExactOutputSingleParams memory params = IV4Router.ExactOutputSingleParams(
            adapterKey, true, uint128(amountOut), uint128(amountInMaximum), 0, bytes("")
        );

        plan = plan.add(Actions.SWAP_EXACT_OUT_SINGLE, abi.encode(params));
        bytes memory data =
            plan.finalizeSwap(permissionsAdapter1Currency, permissionsAdapter0Currency, ActionConstants.MSG_SENDER);

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
        path[0] = permissionsAdapter1Currency;
        path[1] = permissionsAdapter0Currency;

        // Create path keys for the multi-hop swap
        PathKey[] memory pathKeys = new PathKey[](1);
        pathKeys[0] = PathKey({
            intermediateCurrency: permissionsAdapter0Currency,
            fee: 3000,
            tickSpacing: 60,
            hooks: permissionedHooks,
            hookData: bytes("")
        });

        IV4Router.ExactInputParams memory params =
            IV4Router.ExactInputParams(permissionsAdapter1Currency, pathKeys, new uint256[](0), uint128(amountIn), 0);

        plan = plan.add(Actions.SWAP_EXACT_IN, abi.encode(params));
        bytes memory data =
            plan.finalizeSwap(permissionsAdapter1Currency, permissionsAdapter0Currency, ActionConstants.MSG_SENDER);

        vm.prank(alice);
        permissionedRouter.execute(COMMAND_V4_SWAP, toBytesArray(data), type(uint256).max);
    }

    function test_router_user_payment_permissioned_token() public {
        // Test that SWAP_ALLOWED allows swap operations
        MockPermissionedToken(Currency.unwrap(currency0)).setAllowlist(alice, PermissionFlags.SWAP_ALLOWED);
        MockPermissionedToken(Currency.unwrap(currency1)).setAllowlist(alice, PermissionFlags.SWAP_ALLOWED);

        IERC20(Currency.unwrap(currency0)).transfer(alice, 2 ether);
        IERC20(Currency.unwrap(currency1)).transfer(alice, 2 ether);

        uint256 amountIn = 100;
        PoolKey memory adapterKey =
            PoolKey(permissionsAdapter1Currency, permissionsAdapter0Currency, 3000, 60, permissionedHooks);

        IV4Router.ExactInputSingleParams memory params =
            IV4Router.ExactInputSingleParams(adapterKey, true, uint128(amountIn), 0, 0, bytes(""));

        plan = plan.add(Actions.SWAP_EXACT_IN_SINGLE, abi.encode(params));
        bytes memory data =
            plan.finalizeSwap(permissionsAdapter1Currency, permissionsAdapter0Currency, ActionConstants.MSG_SENDER);

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
        IV4Router.ExactInputSingleParams memory params = IV4Router.ExactInputSingleParams(
            key0, true, uint128(amountIn), uint128(expectedAmountOut + 1), 0, bytes("")
        );

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
            IV4Router.ExactInputSingleParams(key0, true, uint128(amountIn), 0, 0, bytes(""));

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
            IV4Router.ExactInputSingleParams(key0, true, uint128(amountIn), 0, 0, bytes(""));

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
            IV4Router.ExactInputSingleParams(key0, true, uint128(amountIn), 0, 0, bytes(""));

        plan = plan.add(Actions.SWAP_EXACT_IN_SINGLE, abi.encode(params));

        // the router holds no funds before
        assertEq(permissionsAdapter0.balanceOf(address(permissionedRouter)), 0);
        assertEq(permissionsAdapter1.balanceOf(address(permissionedRouter)), 0);

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
            IV4Router.ExactInputSingleParams(key0, true, uint128(amountIn), 0, 0, bytes(""));

        Currency inputCurrency = getPermissionedCurrency(key0.currency0);
        Currency outputCurrency = getPermissionedCurrency(key0.currency1);

        plan = plan.add(Actions.SWAP_EXACT_IN_SINGLE, abi.encode(params));
        plan = plan.add(Actions.SETTLE_ALL, abi.encode(key0.currency0, expectedAmountOut * 12 / 10));
        // take the entire open delta to the router's address
        plan = plan.add(
            Actions.TAKE, abi.encode(key0.currency1, ActionConstants.ADDRESS_THIS, ActionConstants.OPEN_DELTA)
        );
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
            IV4Router.ExactInputSingleParams(key0, zeroForOne, uint128(amountIn), 0, 0, bytes(""));

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

        tokenPath.push(permissionsAdapter0Currency);
        tokenPath.push(permissionsAdapter1Currency);

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

        tokenPath.push(permissionsAdapter0Currency);
        tokenPath.push(permissionsAdapter1Currency);

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
        ) = _finalizeAndExecuteSwap(permissionsAdapter0Currency, permissionsAdapter1Currency, amountIn);
        (uint256 inputBalanceAfter, uint256 outputBalanceAfter,) =
            getInputAndOutputBalancesPath(tokenPath, address(manager));

        assertEq(permissionsAdapter0.balanceOf(address(permissionedRouter)), 0);
        assertEq(permissionsAdapter1.balanceOf(address(permissionedRouter)), 0);
        assertEq(userInputBalanceBefore - userInputBalanceAfter, amountIn);
        assertEq(userOutputBalanceAfter - userOutputBalanceBefore, expectedAmountOut);
        assertEq(inputBalanceAfter - inputBalanceBefore, amountIn);
        assertEq(outputBalanceBefore - outputBalanceAfter, expectedAmountOut);
    }

    function test_swapExactIn_1Hop_oneForZero() public {
        uint256 amountIn = 1 ether;
        uint256 expectedAmountOut = 19992;

        tokenPath.push(permissionsAdapter1Currency);
        tokenPath.push(permissionsAdapter0Currency);

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
        ) = _finalizeAndExecuteSwap(permissionsAdapter1Currency, permissionsAdapter0Currency, amountIn);
        (uint256 inputBalanceAfter, uint256 outputBalanceAfter,) =
            getInputAndOutputBalancesPath(tokenPath, address(manager));

        assertEq(permissionsAdapter0.balanceOf(address(permissionedRouter)), 0);
        assertEq(permissionsAdapter1.balanceOf(address(permissionedRouter)), 0);
        assertEq(userInputBalanceBefore - userInputBalanceAfter, amountIn);
        assertEq(userOutputBalanceAfter - userOutputBalanceBefore, expectedAmountOut);
        assertEq(inputBalanceAfter - inputBalanceBefore, amountIn);
        assertEq(outputBalanceBefore - outputBalanceAfter, expectedAmountOut);
    }

    function test_swapExactIn_2Hops() public {
        uint256 amountIn = 1 ether;
        uint256 expectedAmountOut = 9982;

        tokenPath.push(permissionsAdapter0Currency);
        tokenPath.push(permissionsAdapter1Currency);
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
        ) = _finalizeAndExecuteSwap(permissionsAdapter0Currency, currency2, amountIn);
        (uint256 inputBalanceAfter, uint256 outputBalanceAfter,) =
            getInputAndOutputBalancesPath(tokenPath, address(manager));

        // check intermediate token balances
        assertEq(intermediateBalanceBefore, currency1.balanceOfSelf());
        assertEq(permissionsAdapter0.balanceOf(address(permissionedRouter)), 0);
        assertEq(permissionsAdapter1.balanceOf(address(permissionedRouter)), 0);
        assertEq(currency2.balanceOf(address(permissionedRouter)), 0);
        assertEq(userInputBalanceBefore - userInputBalanceAfter, amountIn);
        assertEq(userOutputBalanceAfter - userOutputBalanceBefore, expectedAmountOut);
        assertEq(inputBalanceAfter - inputBalanceBefore, amountIn);
        assertEq(outputBalanceBefore - outputBalanceAfter, expectedAmountOut);
    }

    function test_swapExactIn_3Hops() public {
        uint256 amountIn = 1 ether;
        uint256 expectedAmountOut = 6645;

        tokenPath.push(permissionsAdapter0Currency);
        tokenPath.push(permissionsAdapter1Currency);
        tokenPath.push(currency2);
        tokenPath.push(currency3);

        // Build path manually: first two hops use permissionedHooks, last hop uses address(0) (key2 is hookless)
        PathKey[] memory path = new PathKey[](3);
        path[0] = PathKey(permissionsAdapter1Currency, 3000, 60, IHooks(address(permissionedHooks)), bytes(""));
        path[1] = PathKey(currency2, 3000, 60, IHooks(address(permissionedHooks)), bytes(""));
        path[2] = PathKey(currency3, 3000, 60, IHooks(address(0)), bytes(""));
        IV4Router.ExactInputParams memory params = IV4Router.ExactInputParams({
            currencyIn: permissionsAdapter0Currency,
            path: path,
            minHopPriceX36: new uint256[](0),
            amountIn: uint128(amountIn),
            amountOutMinimum: uint128(expectedAmountOut)
        });

        plan = plan.add(Actions.SWAP_EXACT_IN, abi.encode(params));

        (uint256 inputBalanceBefore, uint256 outputBalanceBefore,) =
            getInputAndOutputBalancesPath(tokenPath, address(manager));
        (
            uint256 userInputBalanceBefore,
            uint256 userOutputBalanceBefore,
            uint256 userInputBalanceAfter,
            uint256 userOutputBalanceAfter
        ) = _finalizeAndExecuteSwap(permissionsAdapter0Currency, currency3, amountIn);
        (uint256 inputBalanceAfter, uint256 outputBalanceAfter,) =
            getInputAndOutputBalancesPath(tokenPath, address(manager));

        // check intermediate tokens werent left in the router
        assertEq(permissionsAdapter0.balanceOf(address(permissionedRouter)), 0);
        assertEq(permissionsAdapter1.balanceOf(address(permissionedRouter)), 0);
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
            IV4Router.ExactInputSingleParams(nativeKey, true, uint128(amountIn), 0, 0, bytes(""));

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
            IV4Router.ExactInputSingleParams(nativeKey, zeroForOne, uint128(amountIn), 0, 0, bytes(""));

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
        tokenPath.push(permissionsAdapter0Currency);
        tokenPath.push(permissionsAdapter1Currency);

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
        ) = _finalizeAndExecuteSwap(CurrencyLibrary.ADDRESS_ZERO, permissionsAdapter1Currency, amountIn);
        (, uint256 outputBalanceAfter, uint256 ethBalanceAfter) =
            getInputAndOutputBalancesPath(tokenPath, address(manager));

        // check intermediate token balances
        assertEq(intermediateBalanceBefore, currency0.balanceOfSelf());
        assertEq(userInputBalanceBefore - userInputBalanceAfter, amountIn);
        assertEq(userOutputBalanceAfter - userOutputBalanceBefore, expectedAmountOut);
        assertEq(nativeKey.currency0.balanceOf(address(permissionedRouter)), 0);
        assertEq(nativeKey.currency1.balanceOf(address(permissionedRouter)), 0);
        assertEq(permissionsAdapter1.balanceOf(address(permissionedRouter)), 0);
        assertEq(ethBalanceBefore - ethBalanceAfter, amountIn);
        assertEq(outputBalanceBefore - outputBalanceAfter, expectedAmountOut);
    }

    function test_nativeOut_swapExactIn_2Hops() public {
        uint256 amountIn = 1 ether;
        uint256 expectedAmountOut = 9982;

        // the initialized nativeKey is (native, currency0)
        tokenPath.push(permissionsAdapter1Currency);
        tokenPath.push(permissionsAdapter0Currency);
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
        ) = _finalizeAndExecuteSwap(permissionsAdapter1Currency, CurrencyLibrary.ADDRESS_ZERO, amountIn);
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
            IV4Router.ExactInputSingleParams(nativeKey, zeroForOne, ActionConstants.OPEN_DELTA, 0, 0, bytes(""));

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

        IV4Router.ExactOutputSingleParams memory params = IV4Router.ExactOutputSingleParams(
            key0, true, uint128(amountOut), uint128(expectedAmountIn - 1), 0, bytes("")
        );

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
            key0, zeroForOne, uint128(amountOut), uint128(expectedAmountIn + 1), 0, bytes("")
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
            key0, zeroForOne, uint128(amountOut), uint128(expectedAmountIn + 1), 0, bytes("")
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

        assertEq(permissionsAdapter0.balanceOf(address(permissionedRouter)), 0);
        assertEq(permissionsAdapter1.balanceOf(address(permissionedRouter)), 0);
        assertEq(userInputBalanceBefore - userInputBalanceAfter, expectedAmountIn);
        assertEq(userOutputBalanceAfter - userOutputBalanceBefore, amountOut);
        assertEq(outputBalanceBefore - outputBalanceAfter, amountOut);
        assertEq(inputBalanceAfter - inputBalanceBefore, expectedAmountIn);
    }

    function test_swapExactOut_revertsForAmountIn() public {
        uint256 amountOut = 1 ether;
        uint256 expectedAmountIn = 369070324262815812743748;

        tokenPath.push(permissionsAdapter0Currency);
        tokenPath.push(permissionsAdapter1Currency);

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

        tokenPath.push(permissionsAdapter1Currency);
        tokenPath.push(permissionsAdapter0Currency);

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

        assertEq(permissionsAdapter0.balanceOf(address(permissionedRouter)), 0);
        assertEq(permissionsAdapter1.balanceOf(address(permissionedRouter)), 0);
        assertEq(userInputBalanceBefore - userInputBalanceAfter, expectedAmountIn);
        assertEq(userOutputBalanceAfter - userOutputBalanceBefore, amountOut);
        assertEq(outputBalanceBefore - outputBalanceAfter, amountOut);
        assertEq(inputBalanceAfter - inputBalanceBefore, expectedAmountIn);
    }

    function test_swapExactOut_1Hop_oneForZero() public {
        uint256 amountOut = 19992;
        uint256 expectedAmountIn = 433302557;

        tokenPath.push(permissionsAdapter0Currency);
        tokenPath.push(permissionsAdapter1Currency);

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
        ) = _finalizeAndExecuteSwap(permissionsAdapter0Currency, key0.currency0, expectedAmountIn);
        (uint256 inputBalanceAfter, uint256 outputBalanceAfter,) =
            getInputAndOutputBalancesPath(tokenPath, address(manager));

        assertEq(permissionsAdapter0.balanceOf(address(permissionedRouter)), 0);
        assertEq(permissionsAdapter1.balanceOf(address(permissionedRouter)), 0);
        assertEq(userInputBalanceBefore - userInputBalanceAfter, expectedAmountIn);
        assertEq(userOutputBalanceAfter - userOutputBalanceBefore, amountOut);
        assertEq(outputBalanceBefore - outputBalanceAfter, amountOut);
        assertEq(inputBalanceAfter - inputBalanceBefore, expectedAmountIn);
    }

    function test_swapExactOut_2Hops() public {
        uint256 amountOut = 100;
        uint256 expectedAmountIn = 104;

        tokenPath.push(permissionsAdapter0Currency);
        tokenPath.push(permissionsAdapter1Currency);
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
        ) = _finalizeAndExecuteSwap(permissionsAdapter0Currency, currency2, expectedAmountIn);
        (uint256 inputBalanceAfter, uint256 outputBalanceAfter,) =
            getInputAndOutputBalancesPath(tokenPath, address(manager));

        assertEq(intermediateBalanceBefore, currency1.balanceOfSelf());
        assertEq(permissionsAdapter0.balanceOf(address(permissionedRouter)), 0);
        assertEq(permissionsAdapter1.balanceOf(address(permissionedRouter)), 0);
        assertEq(currency2.balanceOf(address(permissionedRouter)), 0);
        assertEq(userInputBalanceBefore - userInputBalanceAfter, expectedAmountIn);
        assertEq(userOutputBalanceAfter - userOutputBalanceBefore, amountOut);
        assertEq(outputBalanceBefore - outputBalanceAfter, amountOut);
        assertEq(inputBalanceAfter - inputBalanceBefore, expectedAmountIn);
    }

    function test_swapExactOut_3Hops() public {
        uint256 amountOut = 100;
        uint256 expectedAmountIn = 106;

        tokenPath.push(permissionsAdapter0Currency);
        tokenPath.push(permissionsAdapter1Currency);
        tokenPath.push(currency2);
        tokenPath.push(currency3);

        // Build path following _getExactOutputParamsWithHook pattern:
        // path[2] = currency2 (hop: currency3→currency2, hookless pool)
        // path[1] = adapter1 (hop: currency2→adapter1, permissioned)
        // path[0] = adapter0 (hop: adapter1→adapter0, permissioned)
        PathKey[] memory path = new PathKey[](3);
        path[0] = PathKey(permissionsAdapter0Currency, 3000, 60, IHooks(address(permissionedHooks)), bytes(""));
        path[1] = PathKey(permissionsAdapter1Currency, 3000, 60, IHooks(address(permissionedHooks)), bytes(""));
        path[2] = PathKey(currency2, 3000, 60, IHooks(address(0)), bytes(""));
        IV4Router.ExactOutputParams memory params = IV4Router.ExactOutputParams({
            currencyOut: currency3,
            path: path,
            minHopPriceX36: new uint256[](0),
            amountOut: uint128(amountOut),
            amountInMaximum: uint128(expectedAmountIn)
        });

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

        assertEq(permissionsAdapter0.balanceOf(address(permissionedRouter)), 0);
        assertEq(permissionsAdapter1.balanceOf(address(permissionedRouter)), 0);
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
        tokenPath.push(permissionsAdapter0Currency);
        tokenPath.push(permissionsAdapter1Currency);
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
        assertEq(permissionsAdapter0.balanceOf(address(permissionedRouter)), 0);
        assertEq(permissionsAdapter1.balanceOf(address(permissionedRouter)), 0);
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
        tokenPath.push(permissionsAdapter0Currency);
        tokenPath.push(permissionsAdapter1Currency);
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
        tokenPath.push(permissionsAdapter0Currency);
        tokenPath.push(permissionsAdapter1Currency);
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
        assertEq(permissionsAdapter0.balanceOf(address(permissionedRouter)), 0);
        assertEq(permissionsAdapter1.balanceOf(address(permissionedRouter)), 0);
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
        tokenPath.push(permissionsAdapter0Currency);
        tokenPath.push(permissionsAdapter1Currency);
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
        permissionedRouter.execute{value: (nativeKey.currency0.isAddressZero()) ? expectedAmountIn : 0}(
            COMMAND_V4_SWAP, toBytesArray(data), type(uint256).max
        );
    }

    function test_swapExactOutputSingle_swapOpenDelta() public {
        uint256 expectedAmountIn = 946;
        uint256 expectedOutput = 900;

        IV4Router.ExactOutputSingleParams memory params = IV4Router.ExactOutputSingleParams(
            key0, true, ActionConstants.OPEN_DELTA, uint128(expectedAmountIn), 0, bytes("")
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

        tokenPath.push(permissionsAdapter1Currency);
        tokenPath.push(permissionsAdapter0Currency);

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
            nativeKey, zeroForOne, uint128(amountOut), uint128(expectedAmountIn + 1), 0, bytes("")
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
            IV4Router.ExactInputSingleParams(key2, true, uint128(amountIn), 0, 0, bytes(""));

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
            IV4Router.ExactInputSingleParams(key0, true, uint128(amountIn), 0, 0, bytes(""));

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

        MockPermissionedToken(Currency.unwrap(getPermissionedCurrency(key0.currency0)))
            .setAllowlist(unauthorizedUser, PermissionFlags.ALL_ALLOWED);
        IERC20(Currency.unwrap(getPermissionedCurrency(key0.currency0))).transfer(address(unauthorizedUser), amountIn);

        vm.prank(unauthorizedUser);
        IERC20(Currency.unwrap(getPermissionedCurrency(key0.currency0))).transfer(address(permissionedRouter), amountIn);

        MockPermissionedToken(Currency.unwrap(getPermissionedCurrency(key0.currency0)))
            .setAllowlist(unauthorizedUser, PermissionFlags.NONE);

        IV4Router.ExactInputSingleParams memory params =
            IV4Router.ExactInputSingleParams(key0, true, uint128(amountIn), 0, 0, bytes(""));

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
                token: Currency.unwrap(currency0), amount: 1e18, expiration: uint48(block.timestamp + 3600), nonce: 0
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
        vm.expectRevert(abi.encodeWithSelector(InvalidCommandType.selector, uint8(0x07)));
        permissionedRouter.execute(hex"07", toBytesArray(data), type(uint256).max);
    }

    function test_failed_call_reverts() public {
        IAllowanceTransfer.PermitSingle memory permitSingle = IAllowanceTransfer.PermitSingle({
            details: IAllowanceTransfer.PermitDetails({
                token: Currency.unwrap(currency0), amount: 1e18, expiration: uint48(block.timestamp + 3600), nonce: 0
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
        ModifyLiquidityParams memory modifyLiquidityParams =
            ModifyLiquidityParams({tickLower: 0, tickUpper: 0, liquidityDelta: 0, salt: bytes32(0)});
        BalanceDelta balanceDelta = BalanceDelta.wrap(0);

        // Use manager to avoid NotPoolManager errors for hooks with OnlyPoolManager modifier
        vm.startPrank(address(manager));
        // afterSwap is implemented and tested separately
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

    /*//////////////////////////////////////////////////////////////
                            SWAP EVENT TESTS
    //////////////////////////////////////////////////////////////*/

    function _assertSwapEventMatchesPoolState(VmSafe.Log memory log, PoolKey memory key) private view {
        (,, uint160 sqrtPriceX96, uint128 liquidity, int24 tick, uint24 fee) =
            abi.decode(log.data, (int128, int128, uint160, uint128, int24, uint24));
        PoolId id = key.toId();
        (uint160 expectedSqrtPrice, int24 expectedTick,, uint24 expectedFee) = manager.getSlot0(id);
        uint128 expectedLiquidity = manager.getLiquidity(id);
        assertEq(sqrtPriceX96, expectedSqrtPrice);
        assertEq(tick, expectedTick);
        assertEq(liquidity, expectedLiquidity);
        assertEq(fee, expectedFee);
    }

    function test_swapExactInputSingle_emitsSwapEvent() public {
        uint256 amountIn = 1 ether;
        PoolKey memory adapterKey =
            PoolKey(permissionsAdapter1Currency, permissionsAdapter0Currency, 3000, 60, permissionedHooks);

        IV4Router.ExactInputSingleParams memory params =
            IV4Router.ExactInputSingleParams(adapterKey, true, uint128(amountIn), 0, 0, bytes(""));

        plan = plan.add(Actions.SWAP_EXACT_IN_SINGLE, abi.encode(params));
        bytes memory data =
            plan.finalizeSwap(permissionsAdapter1Currency, permissionsAdapter0Currency, ActionConstants.MSG_SENDER);

        vm.recordLogs();
        permissionedRouter.execute(COMMAND_V4_SWAP, toBytesArray(data), type(uint256).max);
        VmSafe.Log[] memory logs = vm.getRecordedLogs();

        bytes32 swapTopic = MockPermissionedHooks.Swap.selector;
        bool found = false;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == swapTopic && logs[i].emitter == address(permissionedHooks)) {
                found = true;
                assertEq(logs[i].topics[1], PoolId.unwrap(adapterKey.toId()));
                assertEq(logs[i].topics[2], bytes32(uint256(uint160(address(this)))));

                (int128 amount0, int128 amount1,,,,) =
                    abi.decode(logs[i].data, (int128, int128, uint160, uint128, int24, uint24));
                assertEq(amount0, -int128(int256(amountIn)));
                assertGt(amount1, 0);

                _assertSwapEventMatchesPoolState(logs[i], adapterKey);
                break;
            }
        }
        assertTrue(found, "Swap event not found");
    }

    function test_swapExactOutputSingle_emitsSwapEvent() public {
        uint256 amountOut = 1000;
        PoolKey memory adapterKey =
            PoolKey(permissionsAdapter1Currency, permissionsAdapter0Currency, 3000, 60, permissionedHooks);

        IV4Router.ExactOutputSingleParams memory params =
            IV4Router.ExactOutputSingleParams(adapterKey, true, uint128(amountOut), type(uint128).max, 0, bytes(""));

        plan = plan.add(Actions.SWAP_EXACT_OUT_SINGLE, abi.encode(params));
        bytes memory data =
            plan.finalizeSwap(permissionsAdapter1Currency, permissionsAdapter0Currency, ActionConstants.MSG_SENDER);

        vm.recordLogs();
        permissionedRouter.execute(COMMAND_V4_SWAP, toBytesArray(data), type(uint256).max);
        VmSafe.Log[] memory logs = vm.getRecordedLogs();

        bytes32 swapTopic = MockPermissionedHooks.Swap.selector;
        bool found = false;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == swapTopic && logs[i].emitter == address(permissionedHooks)) {
                found = true;
                assertEq(logs[i].topics[1], PoolId.unwrap(adapterKey.toId()));
                assertEq(logs[i].topics[2], bytes32(uint256(uint160(address(this)))));

                (int128 amount0, int128 amount1,,,,) =
                    abi.decode(logs[i].data, (int128, int128, uint160, uint128, int24, uint24));
                assertLt(amount0, 0);
                assertEq(amount1, int128(int256(amountOut)));

                _assertSwapEventMatchesPoolState(logs[i], adapterKey);
                break;
            }
        }
        assertTrue(found, "Swap event not found");
    }

    function test_swapExactIn_2Hops_emitsSwapEvents() public {
        uint256 amountIn = 1 ether;

        tokenPath.push(permissionsAdapter0Currency);
        tokenPath.push(permissionsAdapter1Currency);
        tokenPath.push(currency2);

        IV4Router.ExactInputParams memory params =
            _getExactInputParamsWithHook(tokenPath, amountIn, address(permissionedHooks));

        plan = plan.add(Actions.SWAP_EXACT_IN, abi.encode(params));
        bytes memory data = plan.finalizeSwap(permissionsAdapter0Currency, currency2, ActionConstants.MSG_SENDER);

        vm.recordLogs();
        permissionedRouter.execute(COMMAND_V4_SWAP, toBytesArray(data), type(uint256).max);
        VmSafe.Log[] memory logs = vm.getRecordedLogs();

        bytes32 swapTopic = MockPermissionedHooks.Swap.selector;
        uint256 swapEventCount = 0;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == swapTopic && logs[i].emitter == address(permissionedHooks)) {
                swapEventCount++;
                assertEq(logs[i].topics[2], bytes32(uint256(uint160(address(this)))));
            }
        }
        assertEq(swapEventCount, 2, "Expected 2 Swap events for 2-hop swap");
    }

    /*//////////////////////////////////////////////////////////////
                    POOL INITIALIZATION TESTS
    //////////////////////////////////////////////////////////////*/

    function test_initialize_reverts_no_verified_adapter() public {
        // Two non-permissioned tokens — neither is a verified adapter
        (Currency c0, Currency c1) = currency2 < currency3 ? (currency2, currency3) : (currency3, currency2);
        PoolKey memory unverifiedKey = PoolKey(c0, c1, 3000, 60, permissionedHooks);
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(permissionedHooks),
                IHooks.beforeInitialize.selector,
                abi.encodeWithSelector(NoVerifiedAdapter.selector),
                abi.encodeWithSelector(HookCallFailed.selector)
            )
        );
        manager.initialize(unverifiedKey, SQRT_PRICE_1_1);
    }

    function test_initialize_succeeds_one_verified_adapter() public {
        Currency adapterCurrency = Currency.wrap(address(permissionsAdapter1));
        (Currency c0, Currency c1) =
            adapterCurrency < currency3 ? (adapterCurrency, currency3) : (currency3, adapterCurrency);
        PoolKey memory oneAdapterKey = PoolKey(c0, c1, 500, 10, permissionedHooks);
        manager.initialize(oneAdapterKey, SQRT_PRICE_1_1);
    }

    function test_initialize_succeeds_two_verified_adapters() public {
        Currency a0 = Currency.wrap(address(permissionsAdapter0));
        Currency a1 = Currency.wrap(address(permissionsAdapter1));
        (Currency c0, Currency c1) = a0 < a1 ? (a0, a1) : (a1, a0);
        PoolKey memory twoAdapterKey = PoolKey(c0, c1, 500, 10, permissionedHooks);
        manager.initialize(twoAdapterKey, SQRT_PRICE_1_1);
    }

    function test_initialize_reverts_unverified_adapter_paired_with_plain_token() public {
        // Create an adapter for a permissioned token but do NOT verify it — the M-03 attack path
        // currency0 is a MockPermissionedToken (first 2 tokens in setup are permissioned)
        IERC20 token = IERC20(Currency.unwrap(currency0));
        MockAllowlistChecker checker = new MockAllowlistChecker();
        address unverifiedAdapter = permissionsAdapterFactory.createPermissionsAdapter(token, address(this), checker);
        // Do NOT verify — skip transferring 1 wei and calling verifyPermissionsAdapter

        Currency adapterCurrency = Currency.wrap(unverifiedAdapter);
        (Currency c0, Currency c1) =
            adapterCurrency < currency4 ? (adapterCurrency, currency4) : (currency4, adapterCurrency);
        PoolKey memory attackKey = PoolKey(c0, c1, 3000, 60, permissionedHooks);
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(permissionedHooks),
                IHooks.beforeInitialize.selector,
                abi.encodeWithSelector(UnverifiedAdapter.selector),
                abi.encodeWithSelector(HookCallFailed.selector)
            )
        );
        manager.initialize(attackKey, SQRT_PRICE_1_1);
    }

    /// @dev Closes the residual M-03 gap: the "at least one verified adapter" rule alone passes when
    /// one side is a verified adapter and the other is a registered-but-unverified adapter. The new
    /// per-currency check must reject this configuration so liquidity cannot be parked one-sided
    /// before the second adapter is verified.
    function test_initialize_reverts_verified_paired_with_unverified_adapter() public {
        // Build a fresh, unverified adapter for a different permissioned token (currency1).
        IERC20 token = IERC20(Currency.unwrap(currency1));
        MockAllowlistChecker checker = new MockAllowlistChecker();
        address unverifiedAdapter = permissionsAdapterFactory.createPermissionsAdapter(token, address(this), checker);
        // Do NOT verify.

        Currency verifiedAdapterCurrency = Currency.wrap(address(permissionsAdapter0));
        Currency unverifiedAdapterCurrency = Currency.wrap(unverifiedAdapter);
        (Currency c0, Currency c1) = verifiedAdapterCurrency < unverifiedAdapterCurrency
            ? (verifiedAdapterCurrency, unverifiedAdapterCurrency)
            : (unverifiedAdapterCurrency, verifiedAdapterCurrency);
        PoolKey memory attackKey = PoolKey(c0, c1, 3000, 60, permissionedHooks);
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(permissionedHooks),
                IHooks.beforeInitialize.selector,
                abi.encodeWithSelector(UnverifiedAdapter.selector),
                abi.encodeWithSelector(HookCallFailed.selector)
            )
        );
        manager.initialize(attackKey, SQRT_PRICE_1_1);
    }

    receive() external payable {}
    fallback() external {}
}
