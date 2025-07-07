// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
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
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {Planner} from "../../../shared/Planner.sol";
import {Plan} from "../../../shared/Planner.sol";
import {IV4Router} from "../../../../src/interfaces/IV4Router.sol";
import {Actions} from "../../../../src/libraries/Actions.sol";
import {ActionConstants} from "../../../../src/libraries/ActionConstants.sol";
import {IWrappedPermissionedTokenFactory} from
    "../../../../src/hooks/permissionedPools/interfaces/IWrappedPermissionedTokenFactory.sol";
import {PermissionedV4Router} from "../../../../src/hooks/permissionedPools/PermissionedV4Router.sol";
import {MockPermissionedToken} from "../PermissionedPoolsBase.sol";
import {MockV4Router} from "../../../mocks/MockV4Router.sol";
import {MockHooks} from "../mocks/MockHooks.sol";
import {Deploy} from "../../../../test/shared/Deploy.sol";
import {HookMiner} from "../../../../src/utils/HookMiner.sol";
import {IWETH9} from "../../../../src/interfaces/external/IWETH9.sol";

/// @notice A contract that provides permissioned deployment functionality for tests
/// This moves the deployFreshManagerAndRoutersPermissioned function from v4-core to the test folder
contract PermissionedDeployers is Test {
    using LPFeeLibrary for uint24;
    using StateLibrary for IPoolManager;

    // Helpful test constants
    bytes public constant ZERO_BYTES = Constants.ZERO_BYTES;
    uint160 public constant SQRT_PRICE_1_1 = Constants.SQRT_PRICE_1_1;
    uint160 public constant SQRT_PRICE_1_2 = Constants.SQRT_PRICE_1_2;
    uint160 public constant SQRT_PRICE_2_1 = Constants.SQRT_PRICE_2_1;
    uint160 public constant SQRT_PRICE_1_4 = Constants.SQRT_PRICE_1_4;
    uint160 public constant SQRT_PRICE_4_1 = Constants.SQRT_PRICE_4_1;

    uint160 public constant MIN_PRICE_LIMIT = TickMath.MIN_SQRT_PRICE + 1;
    uint160 public constant MAX_PRICE_LIMIT = TickMath.MAX_SQRT_PRICE - 1;

    ModifyLiquidityParams public LIQUIDITY_PARAMS =
        ModifyLiquidityParams({tickLower: -120, tickUpper: 120, liquidityDelta: 1e18, salt: 0});
    ModifyLiquidityParams public REMOVE_LIQUIDITY_PARAMS =
        ModifyLiquidityParams({tickLower: -120, tickUpper: 120, liquidityDelta: -1e18, salt: 0});
    SwapParams public SWAP_PARAMS =
        SwapParams({zeroForOne: true, amountSpecified: -100, sqrtPriceLimitX96: SQRT_PRICE_1_2});

    // Global variables
    Currency internal currency0;
    Currency internal currency1;

    IPoolManager public manager;
    PoolModifyLiquidityTest public modifyLiquidityRouter;
    PoolModifyLiquidityTestNoChecks public modifyLiquidityNoChecks;
    SwapRouterNoChecks public swapRouterNoChecks;
    PermissionedV4Router public permissionedSwapRouter;
    PoolSwapTest public swapRouter;
    PoolDonateTest public donateRouter;
    PoolTakeTest public takeRouter;
    ActionsRouter public actionsRouter;
    IHooks public permissionedHooks;
    IHooks public secondaryPermissionedHooks;
    IWrappedPermissionedTokenFactory public wrappedTokenFactory;

    PoolClaimsTest public claimsRouter;
    PoolNestedActionsTest public nestedActionRouter;

    address public feeController;

    PoolKey public nativeKey;
    PoolKey public uninitializedKey;
    PoolKey public uninitializedNativeKey;

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
        deployMiscRouters();
    }

    function deployMiscRouters() internal {
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

    function deployPermissionedHooks(address wrappedTokenFactory_) internal returns (address deployedHooksAddr) {
        uint160 flags = (1 << 11) | (1 << 7);
        (address calculatedAddr, bytes32 salt) = HookMiner.find(
            address(this),
            flags,
            vm.getCode("MockHooks.sol:MockHooks"),
            abi.encode(IWrappedPermissionedTokenFactory(wrappedTokenFactory_))
        );
        address addr = Deploy.create2(
            abi.encodePacked(
                vm.getCode("MockHooks.sol:MockHooks"),
                abi.encode(IWrappedPermissionedTokenFactory(wrappedTokenFactory_))
            ),
            salt
        );
        assertEq(addr, calculatedAddr);
        deployedHooksAddr = calculatedAddr;
    }

    function deployPermissionedV4Router(address permit2_, address wrappedTokenFactory_, address weth9)
        internal
        returns (address deployedAddr)
    {
        bytes memory routerBytecode = abi.encodePacked(
            vm.getCode("PermissionedV4Router.sol:PermissionedV4Router"),
            abi.encode(
                manager,
                IAllowanceTransfer(permit2_),
                IWrappedPermissionedTokenFactory(wrappedTokenFactory_),
                IWETH9(address(weth9))
            )
        );

        deployedAddr = Deploy.create2(routerBytecode, keccak256("permissionedSwapRouter"));
    }

    function deployFreshManagerAndRoutersPermissioned(address permit2_, address weth9) internal {
        deployFreshManager();
        address wrappedTokenFactoryAddress = Deploy.create2(
            abi.encodePacked(
                vm.getCode("WrappedPermissionedTokenFactory.sol:WrappedPermissionedTokenFactory"),
                abi.encode(address(manager))
            ),
            keccak256("wrappedTokenFactory")
        );
        wrappedTokenFactory = IWrappedPermissionedTokenFactory(wrappedTokenFactoryAddress);
        permissionedHooks = IHooks(deployPermissionedHooks(wrappedTokenFactoryAddress));
        secondaryPermissionedHooks = IHooks(deployPermissionedHooks(wrappedTokenFactoryAddress));
        address deployedAddr = deployPermissionedV4Router(permit2_, wrappedTokenFactoryAddress, weth9);
        permissionedSwapRouter = PermissionedV4Router(payable(deployedAddr));
        swapRouter = PoolSwapTest(deployedAddr);
        deployMiscRouters();
    }

    /// @dev You must have first initialised the routers with deployFreshManagerAndRouters
    /// If you only need the currencies (and not approvals) call deployAndMint2Currencies
    function deployMintAndApprove2Currencies(bool isPermissioned0, bool isPermissioned1)
        internal
        returns (Currency, Currency)
    {
        while (true) {
            Currency _currency0;
            Currency _currency1;
            if (isPermissioned0) {
                _currency0 = deployMintAndApproveCurrency(true);
            } else {
                _currency0 = deployMintAndApproveCurrency(false);
            }
            if (isPermissioned1) {
                _currency1 = deployMintAndApproveCurrency(true);
            } else {
                _currency1 = deployMintAndApproveCurrency(false);
            }

            (currency0, currency1) =
                SortTokens.sort(MockERC20(Currency.unwrap(_currency0)), MockERC20(Currency.unwrap(_currency1)));
            if (currency0 == _currency0 && currency1 == _currency1) {
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
        return initPool(
            _currency0, _currency1, hooks, fee, fee.isDynamicFee() ? int24(60) : int24(fee / 100 * 2), sqrtPriceX96
        );
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
