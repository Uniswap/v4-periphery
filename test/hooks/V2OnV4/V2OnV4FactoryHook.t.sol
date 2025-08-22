// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {V2OnV4FactoryHook} from "../../../src/hooks/V2OnV4/V2OnV4FactoryHook.sol";
import {V2OnV4Pair} from "../../../src/hooks/V2OnV4/V2OnV4Pair.sol";
import {IUniswapV2Factory} from "briefcase/protocols/v2-core/interfaces/IUniswapV2Factory.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

contract V2OnV4FactoryHookTest is Test, Deployers {
    using CurrencyLibrary for Currency;

    V2OnV4FactoryHook public factory;
    MockERC20 public token0;
    MockERC20 public token1;
    MockERC20 public token2;
    MockERC20 public token3;

    PoolKey poolKey;
    uint160 constant INIT_SQRT_PRICE = 79228162514264337593543950336; // 1:1 price

    function setUp() public {
        deployFreshManagerAndRouters();

        // Deploy the factory hook with proper permissions
        factory = V2OnV4FactoryHook(
            payable(
                address(
                    uint160(
                        type(uint160).max & clearAllHookPermissionsMask | Hooks.BEFORE_SWAP_FLAG
                            | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
                            | Hooks.BEFORE_INITIALIZE_FLAG
                    )
                )
            )
        );

        deployCodeTo("V2OnV4FactoryHook", abi.encode(manager), address(factory));

        // Deploy test tokens
        token0 = new MockERC20("Token0", "TK0", 18);
        token1 = new MockERC20("Token1", "TK1", 18);
        token2 = new MockERC20("Token2", "TK2", 18);
        token3 = new MockERC20("Token3", "TK3", 18);

        // Ensure token0 < token1 for consistent ordering
        if (address(token0) > address(token1)) {
            (token0, token1) = (token1, token0);
        }

        // Create pool key
        poolKey = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: factory.SWAP_FEE(),
            tickSpacing: factory.TICK_SPACING(),
            hooks: IHooks(address(factory))
        });
    }

    function test_factoryDeployment() public view {
        assertEq(address(factory.poolManager()), address(manager));
        assertEq(factory.feeToSetter(), manager.protocolFeeController());
        assertEq(factory.SWAP_FEE(), 3000);
        assertEq(factory.TICK_SPACING(), 1);
    }

    function test_hookPermissions() public view {
        Hooks.Permissions memory permissions = factory.getHookPermissions();

        assertTrue(permissions.beforeInitialize);
        assertTrue(permissions.beforeAddLiquidity);
        assertTrue(permissions.beforeSwap);
        assertTrue(permissions.beforeSwapReturnDelta);

        assertFalse(permissions.afterInitialize);
        assertFalse(permissions.afterSwap);
        assertFalse(permissions.afterAddLiquidity);
        assertFalse(permissions.afterRemoveLiquidity);
    }

    function test_createPair() public {
        address pairAddress = factory.createPair(address(token0), address(token1));

        // Check pair was created
        assertTrue(pairAddress != address(0));
        assertEq(factory.getPair(address(token0), address(token1)), pairAddress);
        assertEq(factory.getPair(address(token1), address(token0)), pairAddress);

        // Check pair count
        assertEq(factory.allPairsLength(), 1);
        assertEq(factory.allPairs(0), pairAddress);

        // Verify pair properties
        V2OnV4Pair pair = V2OnV4Pair(pairAddress);
        assertEq(Currency.unwrap(pair.token0()), address(token0));
        assertEq(Currency.unwrap(pair.token1()), address(token1));
        assertEq(address(pair.poolManager()), address(manager));
        assertEq(pair.factory(), address(factory));
    }

    function test_createPair_revertsOnDuplicate() public {
        factory.createPair(address(token0), address(token1));

        vm.expectRevert(abi.encodeWithSelector(V2OnV4FactoryHook.PairExists.selector));
        factory.createPair(address(token0), address(token1));

        vm.expectRevert(abi.encodeWithSelector(V2OnV4FactoryHook.PairExists.selector));
        factory.createPair(address(token1), address(token0));
    }

    function test_createPair_revertsOnIdenticalTokens() public {
        vm.expectRevert(abi.encodeWithSelector(V2OnV4FactoryHook.IdenticalAddresses.selector));
        factory.createPair(address(token0), address(token0));
    }

    function test_createPair_revertsOnZeroAddress() public {
        vm.expectRevert(abi.encodeWithSelector(V2OnV4FactoryHook.ZeroAddress.selector));
        factory.createPair(address(0), address(token1));

        vm.expectRevert(abi.encodeWithSelector(V2OnV4FactoryHook.ZeroAddress.selector));
        factory.createPair(address(token0), address(0));
    }

    function test_poolInitialization() public {
        // Initialize should create pair if it doesn't exist
        manager.initialize(poolKey, INIT_SQRT_PRICE);

        address pairAddress = factory.getPair(address(token0), address(token1));
        assertTrue(pairAddress != address(0));
        assertEq(factory.allPairsLength(), 1);
    }

    function test_poolInitialization_revertsOnWrongFee() public {
        PoolKey memory wrongFeeKey = poolKey;
        wrongFeeKey.fee = 500; // Wrong fee

        vm.expectRevert();
        manager.initialize(wrongFeeKey, INIT_SQRT_PRICE);
    }

    function test_poolInitialization_revertsOnWrongTickSpacing() public {
        PoolKey memory wrongTickKey = poolKey;
        wrongTickKey.tickSpacing = 60; // Wrong tick spacing

        vm.expectRevert();
        manager.initialize(wrongTickKey, INIT_SQRT_PRICE);
    }

    function test_setFeeTo() public {
        address newFeeTo = makeAddr("newFeeTo");

        // Should revert if not called by feeToSetter
        vm.prank(address(1));
        vm.expectRevert(V2OnV4FactoryHook.Forbidden.selector);
        factory.setFeeTo(newFeeTo);

        // Should succeed when called by feeToSetter
        address feeToSetter = factory.feeToSetter();
        vm.prank(feeToSetter);
        factory.setFeeTo(newFeeTo);
        assertEq(factory.feeTo(), newFeeTo);
    }

    function test_setFeeToSetter_alwaysReverts() public {
        // feeToSetter is locked and cannot be changed
        vm.expectRevert(V2OnV4FactoryHook.FeeToSetterLocked.selector);
        factory.setFeeToSetter(makeAddr("newSetter"));

        // Even the current feeToSetter cannot change it
        address feeToSetter = factory.feeToSetter();
        vm.prank(feeToSetter);
        vm.expectRevert(V2OnV4FactoryHook.FeeToSetterLocked.selector);
        factory.setFeeToSetter(makeAddr("newSetter"));
    }

    function test_poolInitialization_withExistingPair() public {
        // First create pair manually
        address pairAddress = factory.createPair(address(token0), address(token1));

        // Then initialize pool - should use existing pair
        manager.initialize(poolKey, INIT_SQRT_PRICE);

        // Verify same pair is used
        assertEq(factory.getPair(address(token0), address(token1)), pairAddress);
        assertEq(factory.allPairsLength(), 1);
    }

    function test_poolInitialization_multiplePoolsSamePair() public {
        // Initialize first pool
        manager.initialize(poolKey, INIT_SQRT_PRICE);
        address pairAddress = factory.getPair(address(token0), address(token1));

        // Try to initialize another pool with different sqrtPrice but same tokens
        // This should succeed and use the same pair
        uint160 differentPrice = uint160(TickMath.getSqrtPriceAtTick(100));

        // Since the pool is already initialized with the same key, this should revert
        vm.expectRevert(); // Pool already initialized
        manager.initialize(poolKey, differentPrice);

        // Verify still only one pair exists
        assertEq(factory.allPairsLength(), 1);
        assertEq(factory.getPair(address(token0), address(token1)), pairAddress);
    }

    function test_beforeAddLiquidity_alwaysReverts() public {
        // Initialize pool first
        manager.initialize(poolKey, INIT_SQRT_PRICE);

        // Try to add liquidity - should always revert
        vm.expectRevert();
        modifyLiquidityRouter.modifyLiquidity(
            poolKey,
            ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: 1000000, salt: bytes32(0)}),
            ZERO_BYTES
        );
    }

    function test_feeTo_initialization() public view {
        // Initially feeTo should be zero
        assertEq(factory.feeTo(), address(0));
    }

    function test_initializeWithInvalidHook() public {
        // Create a pool key with wrong hook address
        MockERC20 invalidHook = new MockERC20("Invalid", "INV", 18);

        PoolKey memory invalidPoolKey = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: factory.SWAP_FEE(),
            tickSpacing: factory.TICK_SPACING(),
            hooks: IHooks(address(invalidHook))
        });

        // This should revert when trying to initialize with wrong hook
        vm.expectRevert();
        manager.initialize(invalidPoolKey, INIT_SQRT_PRICE);
    }
}
