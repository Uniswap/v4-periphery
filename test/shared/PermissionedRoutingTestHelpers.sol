// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {Deploy} from "./Deploy.sol";
import {PermissionedPoolModifyLiquidityTest} from "./PermissionedPoolModifyLiquidityTest.sol";
import {PermissionedV4Router} from "../../src/hooks/permissionedPools/PermissionedV4Router.sol";
import {Plan, Planner} from "./Planner.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PathKey} from "../../src/libraries/PathKey.sol";
import {Actions} from "../../src/libraries/Actions.sol";
import {CREATE3} from "solmate/src/utils/CREATE3.sol";
import {WETH} from "solmate/src/tokens/WETH.sol";

import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {LiquidityOperations} from "./LiquidityOperations.sol";
import {IV4Router} from "../../src/interfaces/IV4Router.sol";
import {ActionConstants} from "../../src/libraries/ActionConstants.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {IWrappedPermissionedTokenFactory} from
    "../../src/hooks/permissionedPools/interfaces/IWrappedPermissionedTokenFactory.sol";
import {IWETH9} from "../../src/interfaces/external/IWETH9.sol";
import {IPositionDescriptor} from "../../src/interfaces/IPositionDescriptor.sol";
import {DeployPermit2} from "permit2/test/utils/DeployPermit2.sol";
/// @notice A shared test contract that wraps the v4-core deployers contract and exposes basic helpers for swapping with the permissioned router.

contract PermissionedRoutingTestHelpers is Test, Deployers, DeployPermit2 {
    PermissionedPoolModifyLiquidityTest positionManager;
    PermissionedV4Router permissionedRouter;

    // Permissioned components
    IAllowanceTransfer public permit2;
    IWrappedPermissionedTokenFactory public wrappedTokenFactory;
    address public permissionedPositionManager;

    uint256 MAX_SETTLE_AMOUNT = type(uint256).max;
    uint256 MIN_TAKE_AMOUNT = 0;

    // CREATE3 salts for deterministic deployment
    bytes32 public constant PERMISSIONED_ROUTER_SALT =
        0x0000000000000000000000000000000000000000000000000000000000005fcb;
    bytes32 public constant PERMISSIONED_POSM_SALT = keccak256("PERMISSIONED_POSM_TEST");
    bytes32 public constant WRAPPED_TOKEN_FACTORY_SALT = keccak256("WRAPPED_TOKEN_FACTORY_TEST");

    // nativeKey is already defined in Deployers.sol
    PoolKey key0;
    PoolKey key1;
    PoolKey key2;

    // currency0 and currency1 are defined in Deployers.sol
    Currency currency2;
    Currency currency3;

    Currency[] tokenPath;
    Plan plan;

    function setupPermissionedRouterCurrenciesAndPoolsWithLiquidity() public {
        deployFreshManager();
        WETH wethImpl = new WETH();
        address wethAddr = makeAddr("WETH");
        vm.etch(wethAddr, address(wethImpl).code);
        IWETH9 weth9 = IWETH9(wethAddr);
        IPositionDescriptor tokenDescriptor =
            Deploy.positionDescriptor(address(manager), address(weth9), "ETH", hex"00");
        // Deploy Permit2

        permit2 = IAllowanceTransfer(deployPermit2());

        CREATE3.deploy(
            WRAPPED_TOKEN_FACTORY_SALT,
            abi.encodePacked(
                vm.getCode(
                    "src/hooks/permissionedPools/WrappedPermissionedTokenFactory.sol:WrappedPermissionedTokenFactory"
                ),
                abi.encode(address(manager))
            ),
            0
        );
        wrappedTokenFactory = IWrappedPermissionedTokenFactory(CREATE3.getDeployed(WRAPPED_TOKEN_FACTORY_SALT));

        // Get predicted addresses
        address predictedPositionManager = CREATE3.getDeployed(PERMISSIONED_POSM_SALT);
        address predictedPermissionedRouter = CREATE3.getDeployed(PERMISSIONED_ROUTER_SALT);

        CREATE3.deploy(
            PERMISSIONED_ROUTER_SALT,
            abi.encodePacked(
                vm.getCode("src/hooks/permissionedPools/PermissionedV4Router.sol:PermissionedV4Router"),
                abi.encode(manager, permit2, wrappedTokenFactory, predictedPositionManager)
            ),
            0
        );

        permissionedRouter = PermissionedV4Router(CREATE3.getDeployed(PERMISSIONED_ROUTER_SALT));
        positionManager = new PermissionedPoolModifyLiquidityTest(
            manager, permit2, address(tokenDescriptor), address(weth9), wrappedTokenFactory, predictedPermissionedRouter
        );

        MockERC20[] memory tokens = deployTokensMintAndApprove(4);

        currency0 = Currency.wrap(address(tokens[0]));
        currency1 = Currency.wrap(address(tokens[1]));
        currency2 = Currency.wrap(address(tokens[2]));
        currency3 = Currency.wrap(address(tokens[3]));

        permit2.approve(Currency.unwrap(currency0), address(permissionedRouter), type(uint160).max, 2 ** 47);
        permit2.approve(Currency.unwrap(currency1), address(permissionedRouter), type(uint160).max, 2 ** 47);
        permit2.approve(Currency.unwrap(currency2), address(permissionedRouter), type(uint160).max, 2 ** 47);
        permit2.approve(Currency.unwrap(currency3), address(permissionedRouter), type(uint160).max, 2 ** 47);

        permit2.approve(Currency.unwrap(currency0), address(permissionedPositionManager), type(uint160).max, 2 ** 47);
        permit2.approve(Currency.unwrap(currency1), address(permissionedPositionManager), type(uint160).max, 2 ** 47);
        permit2.approve(Currency.unwrap(currency2), address(permissionedPositionManager), type(uint160).max, 2 ** 47);
        permit2.approve(Currency.unwrap(currency3), address(permissionedPositionManager), type(uint160).max, 2 ** 47);

        nativeKey = createNativePoolWithLiquidity(currency0, address(0));
        key0 = createPoolWithLiquidity(currency0, currency1, address(0));
        key1 = createPoolWithLiquidity(currency1, currency2, address(0));
        key2 = createPoolWithLiquidity(currency2, currency3, address(0));
    }

    function deployTokensMintAndApprove(uint8 count) internal returns (MockERC20[] memory) {
        MockERC20[] memory tokens = deployTokens(count, 2 ** 128);
        for (uint256 i = 0; i < count; i++) {
            tokens[i].approve(address(permissionedRouter), type(uint256).max);
        }
        return tokens;
    }

    function createPoolWithLiquidity(Currency currencyA, Currency currencyB, address hookAddr)
        internal
        returns (PoolKey memory _key)
    {
        if (Currency.unwrap(currencyA) > Currency.unwrap(currencyB)) (currencyA, currencyB) = (currencyB, currencyA);
        _key = PoolKey(currencyA, currencyB, 3000, 60, IHooks(hookAddr));

        manager.initialize(_key, SQRT_PRICE_1_1);
        MockERC20(Currency.unwrap(currencyA)).approve(address(positionManager), type(uint256).max);
        MockERC20(Currency.unwrap(currencyB)).approve(address(positionManager), type(uint256).max);
        positionManager.modifyLiquidity(_key, ModifyLiquidityParams(-887220, 887220, 200 ether, 0), "0x");
    }

    function createNativePoolWithLiquidity(Currency currency, address hookAddr)
        internal
        returns (PoolKey memory _key)
    {
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

    function _finalizeAndExecutePermissionedSwap(
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

        // Execute using the permissioned router
        permissionedRouter.execute{value: value}(data);

        inputBalanceAfter = inputCurrency.balanceOfSelf();
        outputBalanceAfter = outputCurrency.balanceOfSelf();
    }

    function _finalizeAndExecutePermissionedSwap(Currency inputCurrency, Currency outputCurrency, uint256 amountIn)
        internal
        returns (
            uint256 inputBalanceBefore,
            uint256 outputBalanceBefore,
            uint256 inputBalanceAfter,
            uint256 outputBalanceAfter
        )
    {
        return _finalizeAndExecutePermissionedSwap(inputCurrency, outputCurrency, amountIn, ActionConstants.MSG_SENDER);
    }

    function _finalizeAndExecutePermissionedNativeInputExactOutputSwap(
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
        permissionedRouter.execute{value: value}(data);

        inputBalanceAfter = inputCurrency.balanceOfSelf();
        outputBalanceAfter = outputCurrency.balanceOfSelf();
    }

    /// @notice Get the permissioned router address
    function getPermissionedRouter() external view returns (address) {
        return address(permissionedRouter);
    }

    /// @notice Get the permissioned position manager address
    function getPermissionedPositionManager() external view returns (address) {
        return permissionedPositionManager;
    }

    /// @notice Get the permissioned position manager test contract address
    function getPermissionedPositionManagerTest() external view returns (address) {
        return address(positionManager);
    }
}
