// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {ERC20} from "solmate/src/tokens/ERC20.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {MockERC4626} from "solmate/src/test/utils/mocks/MockERC4626.sol";

import {BaseTokenWrapperHook} from "../../src/base/hooks/BaseTokenWrapperHook.sol";
import {ERC4626Hook} from "../../src/hooks/ERC4626Hook.sol";

contract ERC4626HookTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    ERC4626Hook public hook;
    MockERC4626 public vault;
    MockERC20 public asset;
    PoolKey poolKey;
    uint160 initSqrtPriceX96;

    // Users
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    event Transfer(address indexed from, address indexed to, uint256 amount);

    function setUp() public {
        deployFreshManagerAndRouters();

        // Deploy mock asset and vault
        asset = new MockERC20("Asset Token", "ASSET", 18);
        vault = new MockERC4626(asset, "Vault Token", "VAULT");

        // Deploy ERC4626 hook
        hook = ERC4626Hook(
            payable(
                address(
                    uint160(
                        (type(uint160).max & clearAllHookPermissionsMask) | Hooks.BEFORE_SWAP_FLAG
                            | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
                            | Hooks.BEFORE_INITIALIZE_FLAG
                    )
                )
            )
        );
        deployCodeTo("ERC4626Hook", abi.encode(manager, vault), address(hook));

        // Create pool key for asset/vault
        poolKey = PoolKey({
            currency0: Currency.wrap(address(asset)),
            currency1: Currency.wrap(address(vault)),
            fee: 0, // Must be 0 for wrapper pools
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });

        // Initialize pool at 1:1 price
        initSqrtPriceX96 = uint160(TickMath.getSqrtPriceAtTick(0));
        manager.initialize(poolKey, initSqrtPriceX96);

        // Give users some tokens
        asset.mint(alice, 100 ether);
        asset.mint(bob, 100 ether);
        asset.mint(address(this), 200 ether);

        asset.mint(address(this), 400 ether);
        asset.approve(address(vault), 400 ether);
        vault.deposit(100 ether, alice);
        vault.deposit(100 ether, bob);
        vault.deposit(200 ether, address(this));

        _addUnrelatedLiquidity();
    }

    function test_initialization() public view {
        assertEq(address(hook.vault()), address(vault));
        assertEq(Currency.unwrap(hook.wrapperCurrency()), address(vault));
        assertEq(Currency.unwrap(hook.underlyingCurrency()), address(asset));
    }

    function test_wrap_exactInput() public {
        uint256 wrapAmount = 1 ether;
        uint256 expectedOutput = vault.convertToShares(wrapAmount);

        vm.startPrank(alice);
        asset.approve(address(swapRouter), type(uint256).max);

        uint256 aliceAssetBefore = asset.balanceOf(alice);
        uint256 aliceVaultBefore = vault.balanceOf(alice);
        uint256 managerAssetBefore = asset.balanceOf(address(manager));
        uint256 managerVaultBefore = vault.balanceOf(address(manager));

        PoolSwapTest.TestSettings memory testSettings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});
        swapRouter.swap(
            poolKey,
            IPoolManager.SwapParams({
                zeroForOne: true, // asset (0) to vault (1)
                amountSpecified: -int256(wrapAmount),
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            testSettings,
            ""
        );

        vm.stopPrank();

        assertEq(aliceAssetBefore - asset.balanceOf(alice), wrapAmount);
        assertEq(vault.balanceOf(alice) - aliceVaultBefore, expectedOutput);
        assertEq(managerAssetBefore, asset.balanceOf(address(manager)));
        assertEq(managerVaultBefore, vault.balanceOf(address(manager)));
    }

    function test_unwrap_exactInput() public {
        uint256 unwrapAmount = 1 ether;
        uint256 expectedOutput = vault.convertToAssets(unwrapAmount);

        vm.startPrank(alice);
        vault.approve(address(swapRouter), type(uint256).max);

        uint256 aliceAssetBefore = asset.balanceOf(alice);
        uint256 aliceVaultBefore = vault.balanceOf(alice);
        uint256 managerAssetBefore = asset.balanceOf(address(manager));
        uint256 managerVaultBefore = vault.balanceOf(address(manager));

        PoolSwapTest.TestSettings memory testSettings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});
        swapRouter.swap(
            poolKey,
            IPoolManager.SwapParams({
                zeroForOne: false, // vault (1) to asset (0)
                amountSpecified: -int256(unwrapAmount),
                sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
            }),
            testSettings,
            ""
        );

        vm.stopPrank();

        assertEq(asset.balanceOf(alice) - aliceAssetBefore, expectedOutput);
        assertEq(aliceVaultBefore - vault.balanceOf(alice), unwrapAmount);
        assertEq(managerAssetBefore, asset.balanceOf(address(manager)));
        assertEq(managerVaultBefore, vault.balanceOf(address(manager)));
    }

    function test_wrap_exactOutput() public {
        uint256 wrapAmount = 1 ether;
        uint256 expectedInput = vault.convertToAssets(wrapAmount);

        vm.startPrank(alice);
        asset.approve(address(swapRouter), type(uint256).max);

        uint256 aliceAssetBefore = asset.balanceOf(alice);
        uint256 aliceVaultBefore = vault.balanceOf(alice);
        uint256 managerAssetBefore = asset.balanceOf(address(manager));
        uint256 managerVaultBefore = vault.balanceOf(address(manager));

        PoolSwapTest.TestSettings memory testSettings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});
        swapRouter.swap(
            poolKey,
            IPoolManager.SwapParams({
                zeroForOne: true, // asset (0) to vault (1)
                amountSpecified: int256(wrapAmount),
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            testSettings,
            ""
        );

        vm.stopPrank();

        assertEq(aliceAssetBefore - asset.balanceOf(alice), expectedInput);
        assertEq(vault.balanceOf(alice) - aliceVaultBefore, wrapAmount);
        assertEq(managerAssetBefore, asset.balanceOf(address(manager)));
        assertEq(managerVaultBefore, vault.balanceOf(address(manager)));
    }

    function test_unwrap_exactOutput() public {
        uint256 unwrapAmount = 1 ether;
        uint256 expectedInput = vault.convertToShares(unwrapAmount);

        vm.startPrank(alice);
        vault.approve(address(swapRouter), type(uint256).max);

        uint256 aliceAssetBefore = asset.balanceOf(alice);
        uint256 aliceVaultBefore = vault.balanceOf(alice);
        uint256 managerAssetBefore = asset.balanceOf(address(manager));
        uint256 managerVaultBefore = vault.balanceOf(address(manager));

        PoolSwapTest.TestSettings memory testSettings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});
        swapRouter.swap(
            poolKey,
            IPoolManager.SwapParams({
                zeroForOne: false, // vault (1) to asset (0)
                amountSpecified: int256(unwrapAmount),
                sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
            }),
            testSettings,
            ""
        );

        vm.stopPrank();

        assertEq(asset.balanceOf(alice) - aliceAssetBefore, unwrapAmount);
        assertEq(aliceVaultBefore - vault.balanceOf(alice), expectedInput);
        assertEq(managerAssetBefore, asset.balanceOf(address(manager)));
        assertEq(managerVaultBefore, vault.balanceOf(address(manager)));
    }

    function test_revertAddLiquidity() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook),
                IHooks.beforeAddLiquidity.selector,
                abi.encodeWithSelector(BaseTokenWrapperHook.LiquidityNotAllowed.selector),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );

        modifyLiquidityRouter.modifyLiquidity(
            poolKey,
            IPoolManager.ModifyLiquidityParams({
                tickLower: -120,
                tickUpper: 120,
                liquidityDelta: 1000e18,
                salt: bytes32(0)
            }),
            ""
        );
    }

    function test_revertInvalidPoolInitialization() public {
        // Try to initialize with non-zero fee
        PoolKey memory invalidKey = PoolKey({
            currency0: Currency.wrap(address(asset)),
            currency1: Currency.wrap(address(vault)),
            fee: 3000, // Invalid: must be 0
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });

        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook),
                IHooks.beforeInitialize.selector,
                abi.encodeWithSelector(BaseTokenWrapperHook.InvalidPoolFee.selector),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        manager.initialize(invalidKey, initSqrtPriceX96);

        // Try to initialize with wrong token pair
        MockERC20 randomToken = new MockERC20("Random", "RND", 18);
        // sort tokens
        (Currency currency0, Currency currency1) = address(randomToken) < address(vault)
            ? (Currency.wrap(address(randomToken)), Currency.wrap(address(vault)))
            : (Currency.wrap(address(vault)), Currency.wrap(address(randomToken)));
        invalidKey =
            PoolKey({currency0: currency0, currency1: currency1, fee: 0, tickSpacing: 60, hooks: IHooks(address(hook))});

        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook),
                IHooks.beforeInitialize.selector,
                abi.encodeWithSelector(BaseTokenWrapperHook.InvalidPoolToken.selector),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        manager.initialize(invalidKey, initSqrtPriceX96);
    }

    function _addUnrelatedLiquidity() internal {
        // Create a hookless pool key for asset/vault
        PoolKey memory unrelatedPoolKey = PoolKey({
            currency0: Currency.wrap(address(asset)),
            currency1: Currency.wrap(address(vault)),
            fee: 100,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });

        manager.initialize(unrelatedPoolKey, uint160(TickMath.getSqrtPriceAtTick(0)));

        asset.approve(address(modifyLiquidityRouter), type(uint256).max);
        vault.approve(address(modifyLiquidityRouter), type(uint256).max);
        modifyLiquidityRouter.modifyLiquidity(
            unrelatedPoolKey,
            IPoolManager.ModifyLiquidityParams({
                tickLower: -120,
                tickUpper: 120,
                liquidityDelta: 1000e18,
                salt: bytes32(0)
            }),
            ""
        );
    }
}
