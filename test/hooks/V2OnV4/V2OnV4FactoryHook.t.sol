// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {MockClaimManager} from "../../mocks/MockClaimManager.sol";
import {IV2OnV4Pair} from "../../../src/interfaces/IV2OnV4Pair.sol";
import {IV2OnV4Factory} from "../../../src/interfaces/IV2OnV4Factory.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

contract V2OnV4FactoryHookTest is Test, Deployers {
    using CurrencyLibrary for Currency;

    IV2OnV4Factory public factory;
    MockERC20 public token0;
    MockERC20 public token1;
    MockClaimManager public claimManager;

    address public alice;

    PoolKey poolKey;
    uint160 constant INIT_SQRT_PRICE = 79228162514264337593543950336; // 1:1 price

    function setUp() public {
        deployFreshManagerAndRouters();
        claimManager = new MockClaimManager(manager);

        // Deploy the factory hook with proper permissions
        factory = IV2OnV4Factory(
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
        alice = makeAddr("alice");
        token0 = new MockERC20("Token0", "TK0", 18);
        token1 = new MockERC20("Token1", "TK1", 18);
        token0.mint(alice, 1000 ether);
        token1.mint(alice, 1000 ether);

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
        IV2OnV4Pair pair = IV2OnV4Pair(pairAddress);
        assertEq(Currency.unwrap(pair.token0()), address(token0));
        assertEq(Currency.unwrap(pair.token1()), address(token1));
        assertEq(address(pair.poolManager()), address(manager));
        assertEq(pair.factory(), address(factory));
    }

    function test_createPair_revertsOnDuplicate() public {
        factory.createPair(address(token0), address(token1));

        vm.expectRevert(abi.encodeWithSelector(IV2OnV4Factory.PairExists.selector));
        factory.createPair(address(token0), address(token1));

        vm.expectRevert(abi.encodeWithSelector(IV2OnV4Factory.PairExists.selector));
        factory.createPair(address(token1), address(token0));
    }

    function test_createPair_revertsOnIdenticalTokens() public {
        vm.expectRevert(abi.encodeWithSelector(IV2OnV4Factory.IdenticalAddresses.selector));
        factory.createPair(address(token0), address(token0));
    }

    function test_createPair_revertsOnZeroAddress() public {
        vm.expectRevert(abi.encodeWithSelector(IV2OnV4Factory.ZeroAddress.selector));
        factory.createPair(address(0), address(token1));

        vm.expectRevert(abi.encodeWithSelector(IV2OnV4Factory.ZeroAddress.selector));
        factory.createPair(address(token0), address(0));
    }

    function test_poolInitialization() public {
        // Initialize should create pair if it doesn't exist
        manager.initialize(poolKey, INIT_SQRT_PRICE);
        vm.snapshotGasLastCall("V2OnV4Hook_initialize");

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
        vm.expectRevert(IV2OnV4Factory.Forbidden.selector);
        factory.setFeeTo(newFeeTo);

        // Should succeed when called by feeToSetter
        address feeToSetter = factory.feeToSetter();
        vm.prank(feeToSetter);
        factory.setFeeTo(newFeeTo);
        assertEq(factory.feeTo(), newFeeTo);
    }

    function test_setFeeToSetter_alwaysReverts() public {
        // feeToSetter is locked and cannot be changed
        vm.expectRevert(IV2OnV4Factory.FeeToSetterLocked.selector);
        factory.setFeeToSetter(makeAddr("newSetter"));

        // Even the current feeToSetter cannot change it
        address feeToSetter = factory.feeToSetter();
        vm.prank(feeToSetter);
        vm.expectRevert(IV2OnV4Factory.FeeToSetterLocked.selector);
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

    function test_swapExactInput() public {
        manager.initialize(poolKey, INIT_SQRT_PRICE);
        address pairAddress = factory.getPair(address(token0), address(token1));
        _addLiquidity(pairAddress, 100 ether, 100 ether);

        uint256 aliceBalanceBefore0 = token0.balanceOf(alice);
        uint256 aliceBalanceBefore1 = token1.balanceOf(alice);
        uint256 managerBalanceBefore0 = token0.balanceOf(address(manager));
        uint256 managerBalanceBefore1 = token1.balanceOf(address(manager));

        vm.startPrank(alice);
        PoolSwapTest.TestSettings memory testSettings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});
        token0.approve(address(swapRouter), type(uint256).max);
        swapRouter.swap(
            poolKey,
            SwapParams({
                zeroForOne: true,
                amountSpecified: -int256(1 ether),
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            testSettings,
            ""
        );
        vm.snapshotGasLastCall("V2OnV4Hook_exactInput");

        uint256 aliceBalanceAfter0 = token0.balanceOf(alice);
        uint256 aliceBalanceAfter1 = token1.balanceOf(alice);
        uint256 managerBalanceAfter0 = token0.balanceOf(address(manager));
        uint256 managerBalanceAfter1 = token1.balanceOf(address(manager));
        assertEq(aliceBalanceBefore0 - aliceBalanceAfter0, 1 ether);
        assertEq(aliceBalanceAfter1 - aliceBalanceBefore1, 987158034397061298);
        assertEq(managerBalanceAfter0 - managerBalanceBefore0, 1 ether);
        assertEq(managerBalanceBefore1 - managerBalanceAfter1, 987158034397061298);
    }

    function _addLiquidity(address pair, uint256 amount0, uint256 amount1) internal {
        vm.startPrank(alice);
        token0.transfer(address(pair), amount0);
        token1.transfer(address(pair), amount1);
        IV2OnV4Pair(pair).mint(alice);
        vm.stopPrank();
    }
}
