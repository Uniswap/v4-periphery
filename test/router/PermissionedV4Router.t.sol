// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {IV4Router} from "../../src/interfaces/IV4Router.sol";
import {PermissionedRoutingTestHelpers} from "../shared/PermissionedRoutingTestHelpers.sol";
import {Planner} from "../shared/Planner.sol";
import {Actions} from "../../src/libraries/Actions.sol";
import {ActionConstants} from "../../src/libraries/ActionConstants.sol";
import {MockAllowList} from "../mocks/MockAllowList.sol";
import {IAllowlistChecker} from "../../src/hooks/permissionedPools/interfaces/IAllowlistChecker.sol";
import {WrappedPermissionedToken} from "../../src/hooks/permissionedPools/WrappedPermissionedToken.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

contract PermissionedV4RouterTest is PermissionedRoutingTestHelpers {
    MockAllowList public mockAllowList;
    IAllowlistChecker public allowListChecker;
    WrappedPermissionedToken public wrappedToken0;
    WrappedPermissionedToken public wrappedToken1;
    function setUp() public {
        setupPermissionedRouterCurrenciesAndPoolsWithLiquidity();
        plan = Planner.init();
        
        // Setup permissioned components
        setupPermissionedTokens();
    }

    function setupPermissionedTokens() internal {
        // Deploy mock allow list
        mockAllowList = new MockAllowList();
        mockAllowList.addToAllowList(address(this));
        allowListChecker = IAllowlistChecker(address(mockAllowList));

        // Create wrapped tokens
        wrappedToken0 = WrappedPermissionedToken(
            wrappedTokenFactory.createWrappedPermissionedToken(
                IERC20(Currency.unwrap(currency0)),
                address(this),
                allowListChecker
            )
        );
        
        wrappedToken1 = WrappedPermissionedToken(
            wrappedTokenFactory.createWrappedPermissionedToken(
                IERC20(Currency.unwrap(currency1)),
                address(this),
                allowListChecker
            )
        );

        // Approve wrapped tokens for the router
        wrappedToken0.approve(address(permissionedRouter), type(uint256).max);
        wrappedToken1.approve(address(permissionedRouter), type(uint256).max);
    }

    function test_gas_bytecodeSize() public {
        vm.snapshotValue("PermissionedV4Router_Bytecode", address(permissionedRouter).code.length);
    }

    function test_router_initcodeHash() public {
        vm.snapshotValue(
            "permissioned router initcode hash (without constructor params, as uint256)",
            uint256(keccak256(abi.encodePacked(vm.getCode("PermissionedV4Router.sol:PermissionedV4Router"))))
        );
    }

    /*//////////////////////////////////////////////////////////////
                        PERMISSIONED TOKEN SWAPS
    //////////////////////////////////////////////////////////////*/

    function test_gas_swapExactInputSingle_permissionedTokens() public {
        uint256 amountIn = 1 ether;

        
        PoolKey memory wrappedKey = PoolKey(currency0, currency1, 3000, 60, IHooks(address(0)));

        IV4Router.ExactInputSingleParams memory params =
            IV4Router.ExactInputSingleParams(wrappedKey, true, uint128(amountIn), 0, bytes(""));

        plan = plan.add(Actions.SWAP_EXACT_IN_SINGLE, abi.encode(params));
        bytes memory data = plan.finalizeSwap(currency0, currency1, ActionConstants.MSG_SENDER);

        permissionedRouter.execute(data);
        vm.snapshotGasLastCall("PermissionedV4Router_ExactInputSingle_PermissionedTokens");
    }

    function test_gas_swapExactIn_1Hop_permissionedTokens() public {
        uint256 amountIn = 1 ether;
        
        tokenPath.push(currency0);
        tokenPath.push(currency1);
        IV4Router.ExactInputParams memory params = _getExactInputParams(tokenPath, amountIn);

        plan = plan.add(Actions.SWAP_EXACT_IN, abi.encode(params));
        bytes memory data = plan.finalizeSwap(currency0, currency1, ActionConstants.MSG_SENDER);

        permissionedRouter.execute(data);
        vm.snapshotGasLastCall("PermissionedV4Router_ExactIn1Hop_PermissionedTokens");
    }

    function test_gas_swapExactOutputSingle_permissionedTokens() public {
        uint256 amountOut = 1 ether;

        
        PoolKey memory wrappedKey = PoolKey(currency0, currency1, 3000, 60, IHooks(address(0)));

        IV4Router.ExactOutputSingleParams memory params =
            IV4Router.ExactOutputSingleParams(wrappedKey, true, uint128(amountOut), type(uint128).max, bytes(""));

        plan = plan.add(Actions.SWAP_EXACT_OUT_SINGLE, abi.encode(params));
        bytes memory data = plan.finalizeSwap(currency0, currency1, ActionConstants.MSG_SENDER);

        permissionedRouter.execute(data);
        vm.snapshotGasLastCall("PermissionedV4Router_ExactOutputSingle_PermissionedTokens");
    }

    /*//////////////////////////////////////////////////////////////
                        MIXED TOKEN SWAPS (PERMISSIONED + REGULAR)
    //////////////////////////////////////////////////////////////*/

    function test_gas_swapExactInputSingle_mixedTokens() public {
        uint256 amountIn = 1 ether;

        PoolKey memory mixedKey = PoolKey(currency0, currency1, 3000, 60, IHooks(address(0)));

        IV4Router.ExactInputSingleParams memory params =
            IV4Router.ExactInputSingleParams(mixedKey, true, uint128(amountIn), 0, bytes(""));

        plan = plan.add(Actions.SWAP_EXACT_IN_SINGLE, abi.encode(params));
        bytes memory data = plan.finalizeSwap(currency0, currency1, ActionConstants.MSG_SENDER);

        permissionedRouter.execute(data);
        vm.snapshotGasLastCall("PermissionedV4Router_ExactInputSingle_MixedTokens");
    }

    /*//////////////////////////////////////////////////////////////
                        NATIVE TOKEN SWAPS
    //////////////////////////////////////////////////////////////*/

    function test_gas_nativeIn_swapExactInputSingle() public {
        uint256 amountIn = 1 ether;

        IV4Router.ExactInputSingleParams memory params =
            IV4Router.ExactInputSingleParams(nativeKey, true, uint128(amountIn), 0, bytes(""));

        plan = plan.add(Actions.SWAP_EXACT_IN_SINGLE, abi.encode(params));
        bytes memory data = plan.finalizeSwap(nativeKey.currency0, nativeKey.currency1, ActionConstants.MSG_SENDER);

        permissionedRouter.execute{value: amountIn}(data);
        vm.snapshotGasLastCall("PermissionedV4Router_ExactInputSingle_nativeIn");
    }

    function test_gas_nativeOut_swapExactInputSingle() public {
        uint256 amountIn = 1 ether;

        IV4Router.ExactInputSingleParams memory params =
            IV4Router.ExactInputSingleParams(nativeKey, false, uint128(amountIn), 0, bytes(""));

        plan = plan.add(Actions.SWAP_EXACT_IN_SINGLE, abi.encode(params));
        bytes memory data = plan.finalizeSwap(nativeKey.currency1, nativeKey.currency0, ActionConstants.MSG_SENDER);

        permissionedRouter.execute(data);
        vm.snapshotGasLastCall("PermissionedV4Router_ExactInputSingle_nativeOut");
    }

    /*//////////////////////////////////////////////////////////////
                        PERMISSION TESTS
    //////////////////////////////////////////////////////////////*/

    function test_swap_reverts_unauthorized_user() public {
        address unauthorizedUser = makeAddr("UNAUTHORIZED");
        
        // Don't add unauthorized user to allowlist
        // mockAllowList.addToAllowList(unauthorizedUser); // Commented out intentionally
        
        uint256 amountIn = 1 ether;
        
        PoolKey memory wrappedKey = PoolKey(currency0, currency1, 3000, 60, IHooks(address(0)));

        IV4Router.ExactInputSingleParams memory params =
            IV4Router.ExactInputSingleParams(wrappedKey, true, uint128(amountIn), 0, bytes(""));

        plan = plan.add(Actions.SWAP_EXACT_IN_SINGLE, abi.encode(params));
        bytes memory data = plan.finalizeSwap(currency0, currency1, ActionConstants.MSG_SENDER);

        vm.prank(unauthorizedUser);
        vm.expectRevert(); // Should revert due to unauthorized access
        permissionedRouter.execute(data);
    }

    function test_swap_succeeds_authorized_user() public {
        address authorizedUser = makeAddr("AUTHORIZED");
        
        // Add authorized user to allowlist
        mockAllowList.addToAllowList(authorizedUser);
        
        uint256 amountIn = 1 ether;
        
        PoolKey memory wrappedKey = PoolKey(currency0, currency1, 3000, 60, IHooks(address(0)));

        IV4Router.ExactInputSingleParams memory params =
            IV4Router.ExactInputSingleParams(wrappedKey, true, uint128(amountIn), 0, bytes(""));

        plan = plan.add(Actions.SWAP_EXACT_IN_SINGLE, abi.encode(params));
        bytes memory data = plan.finalizeSwap(currency0, currency1, ActionConstants.MSG_SENDER);

        vm.prank(authorizedUser);
        permissionedRouter.execute(data); // Should succeed
    }
} 