// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

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
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
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
import {WrappedPermissionedToken} from "../../src/hooks/permissionedPools/WrappedPermissionedToken.sol";
import {MockAllowList} from "../mocks/MockAllowList.sol";
import {IAllowlistChecker} from "../../src/hooks/permissionedPools/interfaces/IAllowlistChecker.sol";
import "forge-std/console2.sol";
import {IPositionManager} from "../../src/interfaces/IPositionManager.sol";
import {Actions} from "../../src/libraries/Actions.sol";
/// @notice A shared test contract that wraps the v4-core deployers contract and exposes basic helpers for swapping with the permissioned router.

contract PermissionedRoutingTestHelpers is Deployers, DeployPermit2 {
    address public positionManager;
    PermissionedV4Router permissionedRouter;

    // Permissioned components
    IAllowanceTransfer public permit2;
    IWrappedPermissionedTokenFactory public wrappedTokenFactory;
    MockAllowList public mockAllowList;
    IAllowlistChecker public allowListChecker;

    uint256 MAX_SETTLE_AMOUNT = type(uint256).max;
    uint256 MIN_TAKE_AMOUNT = 0;

    // CREATE3 salts for deterministic deployment
    bytes32 public constant PERMISSIONED_ROUTER_SALT =
        0x0000000000000000000000000000000000000000000000000000000000026385;
    bytes32 public constant PERMISSIONED_POSM_SALT = keccak256("PERMISSIONED_POSM_TEST");
    bytes32 public constant WRAPPED_TOKEN_FACTORY_SALT = keccak256("WRAPPED_TOKEN_FACTORY_TEST");

    // nativeKey is already defined in Deployers.sol
    PoolKey key0;
    PoolKey key1;
    PoolKey key2;

    // currency0 and currency1 are defined in Deployers.sol
    Currency currency2;
    Currency currency3;

    WrappedPermissionedToken public wrappedToken0;
    WrappedPermissionedToken public wrappedToken1;

    Currency[] tokenPath;
    Plan plan;

    function setupPermissionedRouterCurrenciesAndPoolsWithLiquidity(address alice) public {
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

        bytes memory posmBytecode = abi.encodePacked(
            vm.getCode("src/hooks/permissionedPools/PermissionedPositionManager.sol:PermissionedPositionManager"),
            abi.encode(
                manager,
                permit2,
                1e18,
                address(tokenDescriptor),
                address(weth9),
                wrappedTokenFactory,
                predictedPermissionedRouter
            )
        );
        positionManager = CREATE3.deploy(PERMISSIONED_POSM_SALT, posmBytecode, 0);
        console2.log("permissionedRouter", address(permissionedRouter));
        console2.log("predictedPermissionedRouter", predictedPermissionedRouter);
        MockERC20[] memory tokens = deployTokensMintAndApprove(4);

        currency0 = Currency.wrap(address(tokens[0]));
        currency1 = Currency.wrap(address(tokens[1]));
        currency2 = Currency.wrap(address(tokens[2]));
        currency3 = Currency.wrap(address(tokens[3]));
        setupPermissionedTokens(predictedPositionManager, predictedPermissionedRouter);
        approveAllCurrencies(tokens);
        vm.startPrank(alice);
        approveAllCurrencies(tokens);
        vm.stopPrank();
        nativeKey = createNativePoolWithLiquidity(Currency.wrap(address(wrappedToken0)), predictedPermissionedRouter);
        key0 = createPoolWithLiquidity(
            Currency.wrap(address(wrappedToken0)), Currency.wrap(address(wrappedToken1)), predictedPermissionedRouter
        );
        key1 = createPoolWithLiquidity(Currency.wrap(address(wrappedToken1)), currency2, predictedPermissionedRouter);
        key2 = createPoolWithLiquidity(currency2, currency3, predictedPermissionedRouter);
    }

    function approveAllCurrencies(MockERC20[] memory currencies) internal {
        for (uint256 i = 0; i < currencies.length; i++) {
            approveAllContracts(address(currencies[i]));
        }
    }

    function approveAllContracts(address token) internal {
        approveBoth(token, address(permissionedRouter));
        approveBoth(token, address(positionManager));
        approveBoth(token, address(manager));
        approveBoth(token, address(permit2));
    }

    function approveBoth(address token, address approved) internal {
        permit2.approve(token, address(approved), type(uint160).max, 2 ** 47);
        IERC20(token).approve(address(approved), type(uint256).max);
    }

    function setupPermissionedTokens(address predictedPositionManager, address predictedPermissionedRouter) internal {
        mockAllowList = new MockAllowList();
        mockAllowList.addToAllowList(address(this));
        mockAllowList.addToAllowList(address(permissionedRouter));
        mockAllowList.addToAllowList(address(positionManager));
        mockAllowList.addToAllowList(address(wrappedTokenFactory));
        mockAllowList.addToAllowList(address(manager));
        mockAllowList.addToAllowList(address(permit2));
        allowListChecker = IAllowlistChecker(address(mockAllowList));

        wrappedToken0 = WrappedPermissionedToken(
            wrappedTokenFactory.createWrappedPermissionedToken(
                IERC20(Currency.unwrap(currency0)), address(this), allowListChecker
            )
        );
        wrappedToken1 = WrappedPermissionedToken(
            wrappedTokenFactory.createWrappedPermissionedToken(
                IERC20(Currency.unwrap(currency1)), address(this), allowListChecker
            )
        );
        // Transfer some underlying tokens to the wrapped tokens for verification
        IERC20(Currency.unwrap(currency0)).transfer(address(wrappedToken0), 1);
        IERC20(Currency.unwrap(currency1)).transfer(address(wrappedToken1), 1);

        wrappedTokenFactory.verifyWrappedToken(address(wrappedToken0));
        wrappedTokenFactory.verifyWrappedToken(address(wrappedToken1));

        // Add position manager as allowed wrapper
        wrappedToken0.updateAllowedWrapper(positionManager, true);
        wrappedToken1.updateAllowedWrapper(positionManager, true);
        wrappedToken0.updateAllowedWrapper(address(permissionedRouter), true);
        wrappedToken1.updateAllowedWrapper(address(permissionedRouter), true);
        wrappedToken0.updateAllowedWrapper(address(manager), true);
        wrappedToken1.updateAllowedWrapper(address(manager), true);
        console2.log("wrappedToken0", address(wrappedToken0));
        console2.log("wrappedToken1", address(wrappedToken1));
        wrappedToken0.approve(address(predictedPermissionedRouter), type(uint256).max);
        wrappedToken1.approve(address(predictedPermissionedRouter), type(uint256).max);
        wrappedToken0.approve(address(predictedPositionManager), type(uint256).max);
        wrappedToken1.approve(address(predictedPositionManager), type(uint256).max);
        wrappedToken0.approve(address(manager), type(uint256).max);
        wrappedToken1.approve(address(manager), type(uint256).max);
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
        MockERC20(Currency.unwrap(currencyA)).approve(positionManager, type(uint256).max);
        MockERC20(Currency.unwrap(currencyB)).approve(positionManager, type(uint256).max);
        modifyLiquidity(_key, ModifyLiquidityParams(-887220, 887220, 200 ether, 0), "0x", 0);
    }

    function createNativePoolWithLiquidity(Currency currency, address hookAddr)
        internal
        returns (PoolKey memory _key)
    {
        _key = PoolKey(CurrencyLibrary.ADDRESS_ZERO, currency, 3000, 60, IHooks(hookAddr));
        manager.initialize(_key, SQRT_PRICE_1_1);
        MockERC20(Currency.unwrap(currency)).approve(positionManager, type(uint256).max);
        modifyLiquidity(_key, ModifyLiquidityParams(-887220, 887220, 200 ether, 0), "0x", 200 ether);
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

    function _getExactInputParamsWithHook(Currency[] memory _tokenPath, uint256 amountIn, address hookAddr)
        internal
        pure
        returns (IV4Router.ExactInputParams memory params)
    {
        PathKey[] memory path = new PathKey[](_tokenPath.length - 1);
        for (uint256 i = 0; i < _tokenPath.length - 1; i++) {
            path[i] = PathKey(_tokenPath[i + 1], 3000, 60, IHooks(hookAddr), bytes(""));
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

function _getExactOutputParamsWithHook(Currency[] memory _tokenPath, uint256 amountOut, address hookAddr)
        internal
        pure
        returns (IV4Router.ExactOutputParams memory params)
    {
        PathKey[] memory path = new PathKey[](_tokenPath.length - 1);
        for (uint256 i = _tokenPath.length - 1; i > 0; i--) {
            path[i - 1] = PathKey(_tokenPath[i - 1], 3000, 60, IHooks(hookAddr), bytes(""));
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

    /// @notice Get the permissioned position manager test contract address
    function getPermissionedPositionManagerTest() external view returns (address) {
        return positionManager;
    }

    function modifyLiquidity(
        PoolKey memory key,
        ModifyLiquidityParams memory params,
        bytes memory hookData,
        uint256 value
    ) public {
        // Create a plan with the mint position action
        Plan memory plan = Planner.init();
        plan = plan.add(
            Actions.MINT_POSITION,
            abi.encode(key, params.tickLower, params.tickUpper, 20000, 100000, 100000, msg.sender, hookData)
        );

        // Finalize the plan with proper settlement
        bytes memory unlockData = plan.finalizeModifyLiquidityWithSettlePair(key);
        uint256 deadline = block.timestamp + 3600;

        // Call modifyLiquidities with the properly encoded data
        IPositionManager(positionManager).modifyLiquidities{value: value}(unlockData, deadline);
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
        permissionedRouter.execute{value: value}(data);

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
}
