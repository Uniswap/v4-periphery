// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {Planner} from "../../../shared/Planner.sol";
import {Plan} from "../../../shared/Planner.sol";
import {IV4Router} from "../../../../src/interfaces/IV4Router.sol";
import {Actions} from "../../../../src/libraries/Actions.sol";
import {ActionConstants} from "../../../../src/libraries/ActionConstants.sol";
import {IWrappedPermissionedTokenFactory} from
    "../../../../src/hooks/permissionedPools/interfaces/IWrappedPermissionedTokenFactory.sol";
import {PermissionedV4Router} from "../../../../src/hooks/permissionedPools/PermissionedV4Router.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";
import {SortTokens} from "@uniswap/v4-core/test/utils/SortTokens.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {PoolModifyLiquidityTestNoChecks} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTestNoChecks.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {SwapRouterNoChecks} from "@uniswap/v4-core/src/test/SwapRouterNoChecks.sol";
import {PoolDonateTest} from "@uniswap/v4-core/src/test/PoolDonateTest.sol";
import {PoolNestedActionsTest} from "@uniswap/v4-core/src/test/PoolNestedActionsTest.sol";
import {PoolTakeTest} from "@uniswap/v4-core/src/test/PoolTakeTest.sol";
import {PoolClaimsTest} from "@uniswap/v4-core/src/test/PoolClaimsTest.sol";
import {ActionsRouter} from "@uniswap/v4-core/src/test/ActionsRouter.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {CREATE3} from "solmate/src/utils/CREATE3.sol";
import {MockPermissionedToken} from "../PermissionedPoolsBase.sol";

/// @notice A contract that provides permissioned deployment functionality for tests
/// This moves the deployFreshManagerAndRoutersPermissioned function from v4-core to the test folder
contract PermissionedDeployers is Test {
    using LPFeeLibrary for uint24;
    using StateLibrary for IPoolManager;

    // Helpful test constants
    bytes constant ZERO_BYTES = Constants.ZERO_BYTES;
    uint160 constant SQRT_PRICE_1_1 = Constants.SQRT_PRICE_1_1;
    uint160 constant SQRT_PRICE_1_2 = Constants.SQRT_PRICE_1_2;
    uint160 constant SQRT_PRICE_2_1 = Constants.SQRT_PRICE_2_1;
    uint160 constant SQRT_PRICE_1_4 = Constants.SQRT_PRICE_1_4;
    uint160 constant SQRT_PRICE_4_1 = Constants.SQRT_PRICE_4_1;

    uint160 public constant MIN_PRICE_LIMIT = TickMath.MIN_SQRT_PRICE + 1;
    uint160 public constant MAX_PRICE_LIMIT = TickMath.MAX_SQRT_PRICE - 1;
    // Has propoer hook flags
    bytes32 public constant PERMISSIONED_SWAP_ROUTER_SALT = keccak256("salt-43086");

    ModifyLiquidityParams public LIQUIDITY_PARAMS =
        ModifyLiquidityParams({tickLower: -120, tickUpper: 120, liquidityDelta: 1e18, salt: 0});
    ModifyLiquidityParams public REMOVE_LIQUIDITY_PARAMS =
        ModifyLiquidityParams({tickLower: -120, tickUpper: 120, liquidityDelta: -1e18, salt: 0});
    SwapParams public SWAP_PARAMS =
        SwapParams({zeroForOne: true, amountSpecified: -100, sqrtPriceLimitX96: SQRT_PRICE_1_2});

    // Global variables
    Currency internal currency0;
    Currency internal currency1;
    IPoolManager manager;
    PoolModifyLiquidityTest modifyLiquidityRouter;
    PoolModifyLiquidityTestNoChecks modifyLiquidityNoChecks;
    SwapRouterNoChecks swapRouterNoChecks;
    PermissionedV4Router permissionedSwapRouter;
    PoolSwapTest swapRouter;
    PoolDonateTest donateRouter;
    PoolTakeTest takeRouter;
    ActionsRouter actionsRouter;

    PoolClaimsTest claimsRouter;
    PoolNestedActionsTest nestedActionRouter;
    address feeController;

    PoolKey key;
    PoolKey nativeKey;
    PoolKey uninitializedKey;
    PoolKey uninitializedNativeKey;

    // Update this value when you add a new hook flag.
    uint160 hookPermissionCount = 14;
    uint160 clearAllHookPermissionsMask = ~uint160(0) << (hookPermissionCount);

    modifier noIsolate() {
        if (msg.sender != address(this)) {
            (bool success,) = address(this).call(msg.data);
            require(success);
        } else {
            _;
        }
    }

    function deployFreshManager() internal virtual {
        manager = new PoolManager(address(this));
    }

    function deployFreshManagerAndRouters() internal {
        deployFreshManager();
        swapRouter = new PoolSwapTest(manager);
        swapRouterNoChecks = new SwapRouterNoChecks(manager);
        modifyLiquidityRouter = new PoolModifyLiquidityTest(manager);
        modifyLiquidityNoChecks = new PoolModifyLiquidityTestNoChecks(manager);
        donateRouter = new PoolDonateTest(manager);
        takeRouter = new PoolTakeTest(manager);
        claimsRouter = new PoolClaimsTest(manager);
        nestedActionRouter = new PoolNestedActionsTest(manager);
        feeController = makeAddr("feeController");
        actionsRouter = new ActionsRouter(manager);

        manager.setProtocolFeeController(feeController);
    }

    function deployFreshManagerAndRoutersPermissioned(
        address _permit2,
        address _wrappedTokenFactory,
        address _permissionedPositionManager
    ) internal {
        deployFreshManager();

        // Create the bytecode for the router with constructor arguments
        bytes memory routerBytecode = abi.encodePacked(
            vm.getCode("PermissionedV4Router.sol:PermissionedV4Router"),
            abi.encode(
                manager,
                IAllowanceTransfer(_permit2),
                IWrappedPermissionedTokenFactory(_wrappedTokenFactory),
                _permissionedPositionManager
            )
        );

        address deployedAddr = CREATE3.deploy(PERMISSIONED_SWAP_ROUTER_SALT, routerBytecode, 0);
        permissionedSwapRouter = PermissionedV4Router(payable(deployedAddr));
        swapRouter = PoolSwapTest(deployedAddr);
        swapRouterNoChecks = new SwapRouterNoChecks(manager);
        modifyLiquidityRouter = new PoolModifyLiquidityTest(manager);
        modifyLiquidityNoChecks = new PoolModifyLiquidityTestNoChecks(manager);
        donateRouter = new PoolDonateTest(manager);
        takeRouter = new PoolTakeTest(manager);
        claimsRouter = new PoolClaimsTest(manager);
        nestedActionRouter = new PoolNestedActionsTest(manager);
        feeController = makeAddr("feeController");
        actionsRouter = new ActionsRouter(manager);

        manager.setProtocolFeeController(feeController);
    }

    // You must have first initialised the routers with deployFreshManagerAndRouters
    // If you only need the currencies (and not approvals) call deployAndMint2Currencies
    function deployMintAndApprove2Currencies(bool isPermissioned0, bool isPermissioned1)
        internal
        returns (Currency, Currency)
    {
        while (true) {
            Currency _currencyA;
            Currency _currencyB;
            if (isPermissioned0) {
                _currencyA = deployMintAndApproveCurrency(true);
            } else {
                _currencyA = deployMintAndApproveCurrency(false);
            }
            if (isPermissioned1) {
                _currencyB = deployMintAndApproveCurrency(true);
            } else {
                _currencyB = deployMintAndApproveCurrency(false);
            }

            (currency0, currency1) =
                SortTokens.sort(MockERC20(Currency.unwrap(_currencyA)), MockERC20(Currency.unwrap(_currencyB)));
            if (currency0 == _currencyA && currency1 == _currencyB) {
                break;
            }
        }
        return (currency0, currency1);
    }

    function deployMintAndApproveCurrency(bool isPermissioned) internal returns (Currency currency) {
        MockERC20 token = deployTokens(1, 2 ** 255, isPermissioned)[0];

        address[9] memory toApprove = [
            address(swapRouter),
            address(swapRouterNoChecks),
            address(modifyLiquidityRouter),
            address(modifyLiquidityNoChecks),
            address(donateRouter),
            address(takeRouter),
            address(claimsRouter),
            address(nestedActionRouter.executor()),
            address(actionsRouter)
        ];

        for (uint256 i = 0; i < toApprove.length; i++) {
            token.approve(toApprove[i], Constants.MAX_UINT256);
        }

        return Currency.wrap(address(token));
    }

    function deployTokens(uint8 count, uint256 totalSupply, bool arePermissioned)
        internal
        returns (MockERC20[] memory tokens)
    {
        tokens = new MockERC20[](count);
        for (uint8 i = 0; i < count; i++) {
            if (arePermissioned) {
                tokens[i] = MockERC20(address(new MockPermissionedToken()));
                MockPermissionedToken(address(tokens[i])).setAllowlist(address(this), true);
                tokens[i].mint(address(this), totalSupply);
            } else {
                tokens[i] = new MockERC20("TEST", "TEST", 18);
                tokens[i].mint(address(this), totalSupply);
            }
        }
    }

    function initPool(Currency _currency0, Currency _currency1, IHooks hooks, uint24 fee, uint160 sqrtPriceX96)
        internal
        returns (PoolKey memory _key, PoolId id)
    {
        _key = PoolKey(_currency0, _currency1, fee, fee.isDynamicFee() ? int24(60) : int24(fee / 100 * 2), hooks);
        id = _key.toId();
        manager.initialize(_key, sqrtPriceX96);
    }

    function initPool(
        Currency _currency0,
        Currency _currency1,
        IHooks hooks,
        uint24 fee,
        int24 tickSpacing,
        uint160 sqrtPriceX96
    ) internal returns (PoolKey memory _key, PoolId id) {
        _key = PoolKey(_currency0, _currency1, fee, tickSpacing, hooks);
        id = _key.toId();
        manager.initialize(_key, sqrtPriceX96);
    }

    function initPoolAndAddLiquidity(
        Currency _currency0,
        Currency _currency1,
        IHooks hooks,
        uint24 fee,
        uint160 sqrtPriceX96
    ) internal returns (PoolKey memory _key, PoolId id) {
        (_key, id) = initPool(_currency0, _currency1, hooks, fee, sqrtPriceX96);
        modifyLiquidityRouter.modifyLiquidity{value: msg.value}(_key, LIQUIDITY_PARAMS, ZERO_BYTES);
    }

    function initPoolAndAddLiquidityETH(
        Currency _currency0,
        Currency _currency1,
        IHooks hooks,
        uint24 fee,
        uint160 sqrtPriceX96,
        uint256 msgValue
    ) internal returns (PoolKey memory _key, PoolId id) {
        (_key, id) = initPool(_currency0, _currency1, hooks, fee, sqrtPriceX96);
        modifyLiquidityRouter.modifyLiquidity{value: msgValue}(_key, LIQUIDITY_PARAMS, ZERO_BYTES);
    }

    /// @notice Helper function for a simple ERC20 swaps that allows for unlimited price impact
    function swap(PoolKey memory _key, bool zeroForOne, int256 amountSpecified) internal {
        // allow native input for exact-input, guide users to the `swapNativeInput` function
        bool isNativeInput = zeroForOne && _key.currency0.isAddressZero();
        if (isNativeInput) require(0 > amountSpecified, "Use swapNativeInput() for native-token exact-output swaps");

        uint256 value = isNativeInput ? uint256(-amountSpecified) : 0;
        bytes memory data = getSwapData(_key, uint256(-amountSpecified), zeroForOne);
        permissionedSwapRouter.execute{value: value}(data);
    }

    function getSwapData(PoolKey memory poolKey, uint256 amountIn, bool zeroForOne)
        internal
        pure
        returns (bytes memory)
    {
        // Initialize the plan
        Plan memory plan = Planner.init();

        // Create swap parameters
        IV4Router.ExactInputSingleParams memory params = IV4Router.ExactInputSingleParams(
            poolKey, // The pool to swap in
            zeroForOne, // Direction of swap
            uint128(amountIn), // Amount to swap in
            0, // Minimum amount out (0 = no slippage protection)
            bytes("") // Hook data
        );

        // Add the swap action to the plan
        plan = plan.add(Actions.SWAP_EXACT_IN_SINGLE, abi.encode(params));

        // Finalize the plan - this adds SETTLE and TAKE actions
        bytes memory data = plan.finalizeSwap(
            zeroForOne ? poolKey.currency0 : poolKey.currency1, // Input currency
            zeroForOne ? poolKey.currency1 : poolKey.currency0, // Output currency
            ActionConstants.MSG_SENDER // Take recipient
        );

        return data;
    }
}
