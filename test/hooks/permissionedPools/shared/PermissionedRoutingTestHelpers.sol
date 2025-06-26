// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Deploy} from "test/shared/Deploy.sol";
import {MockPermissionedV4Router} from "../mocks/MockPermissionedV4Router.sol";
import {Plan, Planner} from "../../../shared/Planner.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PathKey} from "../../../../src/libraries/PathKey.sol";
import {Actions} from "../../../../src/libraries/Actions.sol";
import {CREATE3} from "solmate/src/utils/CREATE3.sol";
import {WETH} from "solmate/src/tokens/WETH.sol";

import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {LiquidityOperations} from "../../../shared/LiquidityOperations.sol";
import {IV4Router} from "../../../../src/interfaces/IV4Router.sol";
import {ActionConstants} from "../../../../src/libraries/ActionConstants.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {IWrappedPermissionedTokenFactory} from
    "../../../../src/hooks/permissionedPools/interfaces/IWrappedPermissionedTokenFactory.sol";
import {IWETH9} from "../../../../src/interfaces/external/IWETH9.sol";
import {IPositionDescriptor} from "../../../../src/interfaces/IPositionDescriptor.sol";
import {DeployPermit2} from "permit2/test/utils/DeployPermit2.sol";
import {WrappedPermissionedToken} from "../../../../src/hooks/permissionedPools/WrappedPermissionedToken.sol";
import {MockAllowlistChecker, MockPermissionedToken} from "../PermissionedPoolsBase.sol";
import {IAllowlistChecker} from "../../../../src/hooks/permissionedPools/interfaces/IAllowlistChecker.sol";
import {IPositionManager} from "../../../../src/interfaces/IPositionManager.sol";
import {PermissionedDeployers} from "./PermissionedDeployers.sol";

/// @notice A shared test contract that wraps the v4-core deployers contract and exposes basic helpers for swapping with the permissioned router.
contract PermissionedRoutingTestHelpers is PermissionedDeployers, DeployPermit2 {
    // Permissioned components
    MockPermissionedV4Router public permissionedRouter;
    IAllowanceTransfer public permit2;
    IWrappedPermissionedTokenFactory public wrappedTokenFactory;
    MockAllowlistChecker public mockAllowlistChecker;
    IAllowlistChecker public allowListChecker;
    IPositionDescriptor public tokenDescriptor;
    IWETH9 public weth9;

    uint256 MAX_SETTLE_AMOUNT = type(uint256).max;
    uint256 MIN_TAKE_AMOUNT = 0;

    // CREATE3 salts for deterministic deployment
    bytes32 public constant PERMISSIONED_POSM_SALT = keccak256("PERMISSIONED_POSM_TEST");
    bytes32 public constant WRAPPED_TOKEN_FACTORY_SALT = keccak256("WRAPPED_TOKEN_FACTORY_TEST");
    // This specific salt indicates proper hook permissions
    bytes32 public constant PERMISSIONED_ROUTER_SALT = keccak256("salt-43086");

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

    address public predictedPositionManager;
    address public predictedPermissionedRouter;
    address public positionManager;

    mapping(Currency wrappedCurrency => Currency permissionedCurrency) public wrappedToPermissioned;

    function setupPermissionedRouterCurrenciesAndPoolsWithLiquidity(address spender) public {
        predictedPositionManager = CREATE3.getDeployed(PERMISSIONED_POSM_SALT);
        predictedPermissionedRouter = CREATE3.getDeployed(PERMISSIONED_ROUTER_SALT);
        _deployFreshManager();
        _deployWETH();
        _deployPositionDescriptor();
        _deployPermit2();
        _deployWrappedTokenFactory();
        _deployMockPermissionedRouter();
        _deployPositionManager();
        MockERC20[] memory tokens = deployTokensMintAndApprove(5, 2);
        _deployAndSetupTokens(tokens);
        _setupPermissionedTokens(spender);
        _setupApprovals(tokens, spender);
        _createPoolsWithLiquidity();
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

    function getPermissionedCurrency(Currency currency) public view returns (Currency) {
        Currency permissionedCurrency = wrappedToPermissioned[currency];
        if (permissionedCurrency == Currency.wrap(address(0))) {
            return currency;
        }
        return permissionedCurrency;
    }

    function setupPermissionedTokens(address spender) internal {
        _setupMockAllowList(currency0, spender);
        _setupMockAllowList(currency1, spender);

        wrappedToken0 = WrappedPermissionedToken(
            wrappedTokenFactory.createWrappedPermissionedToken(
                IERC20(Currency.unwrap(currency0)), address(this), mockAllowlistChecker
            )
        );
        wrappedToken1 = WrappedPermissionedToken(
            wrappedTokenFactory.createWrappedPermissionedToken(
                IERC20(Currency.unwrap(currency1)), address(this), mockAllowlistChecker
            )
        );

        MockPermissionedToken(Currency.unwrap(currency0)).setAllowlist(address(wrappedToken0), true);
        MockPermissionedToken(Currency.unwrap(currency1)).setAllowlist(address(wrappedToken1), true);

        // Transfer some underlying tokens to the wrapped tokens for verification
        IERC20(Currency.unwrap(currency0)).transfer(address(wrappedToken0), 1);
        IERC20(Currency.unwrap(currency1)).transfer(address(wrappedToken1), 1);

        verifyTokensAndAddWrappers();

        wrappedToPermissioned[Currency.wrap(address(wrappedToken0))] = currency0;
        wrappedToPermissioned[Currency.wrap(address(wrappedToken1))] = currency1;
    }

    function verifyTokensAndAddWrappers() private {
        wrappedTokenFactory.verifyWrappedToken(address(wrappedToken0));
        wrappedTokenFactory.verifyWrappedToken(address(wrappedToken1));

        wrappedToken0.updateAllowedWrapper(address(this), true);
        wrappedToken1.updateAllowedWrapper(address(this), true);
        wrappedToken0.updateAllowedWrapper(positionManager, true);
        wrappedToken1.updateAllowedWrapper(positionManager, true);
        wrappedToken0.updateAllowedWrapper(address(permissionedRouter), true);
        wrappedToken1.updateAllowedWrapper(address(permissionedRouter), true);
    }

    function deployTokensMintAndApprove(uint8 count, uint8 permissionedCount) internal returns (MockERC20[] memory) {
        MockERC20[] memory permissionedTokens = deployTokens(permissionedCount, 2 ** 128, true);
        MockERC20[] memory unpermissionedTokens = deployTokens(count - permissionedCount, 2 ** 128, false);
        MockERC20[] memory tokens = new MockERC20[](count);
        for (uint256 i = 0; i < permissionedCount; i++) {
            tokens[i] = permissionedTokens[i];
        }
        for (uint256 i = 0; i < count - permissionedCount; i++) {
            tokens[i + permissionedCount] = unpermissionedTokens[i];
        }
        for (uint256 i = 0; i < count; i++) {
            tokens[i].approve(address(permissionedRouter), type(uint256).max);
            tokens[i].approve(address(positionManager), type(uint256).max);
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
        return _getExactInputParamsWithHook(_tokenPath, amountIn, hookAddr, 0);
    }

    function _getExactInputParamsWithHook(
        Currency[] memory _tokenPath,
        uint256 amountIn,
        address hookAddr,
        uint256 amountOutMinimum
    ) internal pure returns (IV4Router.ExactInputParams memory params) {
        PathKey[] memory path = new PathKey[](_tokenPath.length - 1);
        for (uint256 i = 0; i < _tokenPath.length - 1; i++) {
            path[i] = PathKey(_tokenPath[i + 1], 3000, 60, IHooks(hookAddr), bytes(""));
        }

        params.currencyIn = _tokenPath[0];
        params.path = path;
        params.amountIn = uint128(amountIn);
        params.amountOutMinimum = uint128(amountOutMinimum);
    }

    function _getExactOutputParams(Currency[] memory _tokenPath, uint256 amountOut)
        internal
        pure
        returns (IV4Router.ExactOutputParams memory params)
    {
        return _getExactOutputParamsWithHook(_tokenPath, amountOut, address(0), type(uint128).max);
    }

    function _getExactOutputParamsWithHook(
        Currency[] memory _tokenPath,
        uint256 amountOut,
        address hookAddr,
        uint256 amountInMaximum
    ) internal pure returns (IV4Router.ExactOutputParams memory params) {
        PathKey[] memory path = new PathKey[](_tokenPath.length - 1);
        for (uint256 i = _tokenPath.length - 1; i > 0; i--) {
            path[i - 1] = PathKey(_tokenPath[i - 1], 3000, 60, IHooks(hookAddr), bytes(""));
        }

        params.currencyOut = _tokenPath[_tokenPath.length - 1];
        params.path = path;
        params.amountOut = uint128(amountOut);
        params.amountInMaximum = uint128(amountInMaximum);
    }

    function modifyLiquidity(
        PoolKey memory key,
        ModifyLiquidityParams memory params,
        bytes memory hookData,
        uint256 value
    ) public {
        // Create a plan with the mint position action
        plan = Planner.init();
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

    // ===== PRIVATE HELPER FUNCTIONS =====

    function _deployFreshManager() private {
        deployFreshManager();
    }

    function _deployWETH() private {
        WETH wethImpl = new WETH();
        address wethAddr = makeAddr("WETH");
        vm.etch(wethAddr, address(wethImpl).code);
        weth9 = IWETH9(wethAddr);
    }

    function _deployPositionDescriptor() private {
        tokenDescriptor = Deploy.positionDescriptor(address(manager), address(weth9), "ETH", hex"00");
    }

    function _deployPermit2() private {
        permit2 = IAllowanceTransfer(deployPermit2());
    }

    function _deployWrappedTokenFactory() private {
        CREATE3.deploy(
            WRAPPED_TOKEN_FACTORY_SALT,
            abi.encodePacked(
                vm.getCode("WrappedPermissionedTokenFactory.sol:WrappedPermissionedTokenFactory"),
                abi.encode(address(manager))
            ),
            0
        );
        wrappedTokenFactory = IWrappedPermissionedTokenFactory(CREATE3.getDeployed(WRAPPED_TOKEN_FACTORY_SALT));
    }

    function _deployMockPermissionedRouter() private {
        // Get predicted addresses

        CREATE3.deploy(
            PERMISSIONED_ROUTER_SALT,
            abi.encodePacked(
                vm.getCode("MockPermissionedV4Router.sol:MockPermissionedV4Router"),
                abi.encode(manager, permit2, wrappedTokenFactory, predictedPositionManager)
            ),
            0
        );
        permissionedRouter = MockPermissionedV4Router(payable(CREATE3.getDeployed(PERMISSIONED_ROUTER_SALT)));
    }

    function _deployPositionManager() private {
        bytes memory posmBytecode = abi.encodePacked(
            vm.getCode("PermissionedPositionManager.sol:PermissionedPositionManager"),
            abi.encode(
                manager,
                permit2,
                1e18,
                address(tokenDescriptor),
                address(weth9),
                wrappedTokenFactory,
                address(permissionedRouter)
            )
        );
        positionManager = CREATE3.deploy(PERMISSIONED_POSM_SALT, posmBytecode, 0);
    }

    function _deployAndSetupTokens(MockERC20[] memory tokens) private {
        currency0 = Currency.wrap(address(tokens[0]));
        currency1 = Currency.wrap(address(tokens[1]));
        currency2 = Currency.wrap(address(tokens[2]));
        currency3 = Currency.wrap(address(tokens[3]));
    }

    function _setupPermissionedTokens(address spender) private {
        setupPermissionedTokens(spender);
    }

    function _setupApprovals(MockERC20[] memory tokens, address alice) private {
        approveAllCurrencies(tokens);
        vm.startPrank(alice);
        approveAllCurrencies(tokens);
        vm.stopPrank();
    }

    function _createPoolsWithLiquidity() private {
        nativeKey = createNativePoolWithLiquidity(Currency.wrap(address(wrappedToken0)), address(permissionedRouter));
        key0 = createPoolWithLiquidity(
            Currency.wrap(address(wrappedToken0)), Currency.wrap(address(wrappedToken1)), address(permissionedRouter)
        );
        key1 = createPoolWithLiquidity(Currency.wrap(address(wrappedToken1)), currency2, address(permissionedRouter));
        key2 = createPoolWithLiquidity(currency2, currency3, address(permissionedRouter));
    }

    function _setupMockAllowList(Currency currency, address spender) private {
        MockPermissionedToken mockPermissionedToken = MockPermissionedToken(Currency.unwrap(currency));
        mockAllowlistChecker = new MockAllowlistChecker(mockPermissionedToken);
        mockPermissionedToken.setAllowlist(address(this), true);
        mockPermissionedToken.setAllowlist(address(permissionedRouter), true);
        mockPermissionedToken.setAllowlist(address(positionManager), true);
        mockPermissionedToken.setAllowlist(address(wrappedTokenFactory), true);
        mockPermissionedToken.setAllowlist(address(manager), true);
        mockPermissionedToken.setAllowlist(address(permit2), true);
        mockPermissionedToken.setAllowlist(spender, true);
    }
}
