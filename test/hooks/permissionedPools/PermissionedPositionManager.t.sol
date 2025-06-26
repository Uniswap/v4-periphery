// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "forge-std/Test.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FixedPointMathLib} from "solmate/src/utils/FixedPointMathLib.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {Position} from "@uniswap/v4-core/src/libraries/Position.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import {CREATE3} from "solmate/src/utils/CREATE3.sol";

import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {IERC721} from "forge-std/interfaces/IERC721.sol";

import {IPositionManager} from "../../../src/interfaces/IPositionManager.sol";
import {Actions} from "../../../src/libraries/Actions.sol";
import {DeltaResolver} from "../../../src/base/DeltaResolver.sol";
import {PositionConfig} from "test/shared/PositionConfig.sol";
import {SlippageCheck} from "../../../src/libraries/SlippageCheck.sol";
import {BaseActionsRouter} from "../../../src/base/BaseActionsRouter.sol";
import {ActionConstants} from "../../../src/libraries/ActionConstants.sol";

import {LiquidityFuzzers} from "../../shared/fuzz/LiquidityFuzzers.sol";
import {Planner, Plan} from "../../shared/Planner.sol";
import {PermissionedPosmTestSetup} from "./shared/PermissionedPosmTestSetup.sol";
import {ReentrantToken} from "../../mocks/ReentrantToken.sol";
import {ReentrancyLock} from "../../../src/base/ReentrancyLock.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {MockAllowList} from "../../mocks/MockAllowList.sol";
import {IAllowlistChecker} from "../../../src/hooks/permissionedPools/interfaces/IAllowlistChecker.sol";
import {WrappedPermissionedToken, IERC20} from "../../../src/hooks/permissionedPools/WrappedPermissionedToken.sol";
import {WrappedPermissionedTokenFactory} from "../../../src/hooks/permissionedPools/WrappedPermissionedTokenFactory.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {SortTokens} from "@uniswap/v4-core/test/utils/SortTokens.sol";
import "forge-std/console2.sol";

contract PermissionedPositionManagerTest is Test, PermissionedPosmTestSetup, LiquidityFuzzers {
    using FixedPointMathLib for uint256;
    using StateLibrary for IPoolManager;

    address alice = makeAddr("ALICE");
    PoolId poolId;

    // Permissioned components
    MockAllowList public mockAllowList;
    IAllowlistChecker public allowListChecker;
    WrappedPermissionedToken public wrappedToken0;
    MockERC20 public originalToken0;
    WrappedPermissionedTokenFactory public wrappedTokenFactory;
    Currency public orderedCurrency0;
    Currency public orderedCurrency1;
    address public predictedPermissionedSwapRouterAddress;
    address public predictedPermissionedPosmAddress;
    address public predictedWrappedTokenFactoryAddress;

    // CREATE3 variables for deterministic deployment
    bytes32 public constant PERMISSIONED_POSM_SALT = keccak256("PERMISSIONED_POSM_TEST");
    bytes32 public constant WRAPPED_TOKEN_FACTORY_SALT = keccak256("WRAPPED_TOKEN_FACTORY_TEST");

    function setUp() public {
        // Calculate predicted addresses for contracts using CREATE3
        predictedPermissionedPosmAddress = CREATE3.getDeployed(PERMISSIONED_POSM_SALT);
        predictedPermissionedSwapRouterAddress = CREATE3.getDeployed(PERMISSIONED_SWAP_ROUTER_SALT);
        predictedWrappedTokenFactoryAddress = CREATE3.getDeployed(WRAPPED_TOKEN_FACTORY_SALT);

        wrappedTokenFactory = WrappedPermissionedTokenFactory(predictedWrappedTokenFactoryAddress);

        // Initialize permit2 first since it's needed by deployFreshManagerAndRoutersPermissioned
        permit2 = IAllowanceTransfer(deployPermit2());
        deployFreshManagerAndRoutersPermissioned(
            address(permit2), address(wrappedTokenFactory), predictedPermissionedPosmAddress
        );
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
        (currency0, currency1) = deployMintAndApprove2Currencies();

        // Set up permissioned components
        setupPermissionedComponents();
        // Deploy permissioned position manager instead of regular one
        deployAndApprovePosm(
            manager, address(wrappedTokenFactory), predictedPermissionedSwapRouterAddress, PERMISSIONED_POSM_SALT
        );
        (orderedCurrency0, orderedCurrency1) =
            SortTokens.sort(MockERC20(address(wrappedToken0)), MockERC20(Currency.unwrap(currency1)));

        (key, poolId) = initPool(
            orderedCurrency0, orderedCurrency1, IHooks(predictedPermissionedSwapRouterAddress), 3000, SQRT_PRICE_1_1
        );

        seedBalance(alice);
        approvePosmFor(alice);
    }

    function setupPermissionedComponents() internal {
        // Deploy mock allow list
        mockAllowList = new MockAllowList();
        mockAllowList.addToAllowList(address(this));
        mockAllowList.addToAllowList(alice);
        mockAllowList.addToAllowList(address(predictedPermissionedPosmAddress));
        mockAllowList.addToAllowList(address(wrappedTokenFactory));
        mockAllowList.addToAllowList(address(predictedPermissionedSwapRouterAddress));
        allowListChecker = IAllowlistChecker(address(mockAllowList));

        // Create wrapped token from original token0
        originalToken0 = MockERC20(Currency.unwrap(currency0));
        wrappedToken0 = WrappedPermissionedToken(
            wrappedTokenFactory.createWrappedPermissionedToken(
                IERC20(address(originalToken0)), address(this), allowListChecker
            )
        );
        currency0.transfer(address(wrappedToken0), 1);
        wrappedToken0.updateAllowedWrapper(address(manager), true);
        wrappedToken0.updateAllowedWrapper(address(predictedPermissionedPosmAddress), true);

        wrappedTokenFactory.verifyWrappedToken(address(wrappedToken0));
        // Sort currencies again after wrapping
        (currency0, currency1) =
            (Currency.unwrap(currency0) < Currency.unwrap(currency1)) ? (currency0, currency1) : (currency1, currency0);
    }

    function test_modifyLiquidities_reverts_deadlinePassed() public {
        PositionConfig memory config = PositionConfig({poolKey: key, tickLower: 0, tickUpper: 60});
        bytes memory calls = getMintEncoded(config, 1e18, ActionConstants.MSG_SENDER, "");

        uint256 deadline = vm.getBlockTimestamp() - 1;

        vm.expectRevert(abi.encodeWithSelector(IPositionManager.DeadlinePassed.selector, deadline));
        lpm.modifyLiquidities(calls, deadline);
    }

    function test_modifyLiquidities_reverts_mismatchedLengths() public {
        Plan memory planner = Planner.init();
        planner.add(Actions.MINT_POSITION, abi.encode("test"));
        planner.add(Actions.BURN_POSITION, abi.encode("test"));

        bytes[] memory badParams = new bytes[](1);

        vm.expectRevert(BaseActionsRouter.InputLengthMismatch.selector);
        lpm.modifyLiquidities(abi.encode(planner.actions, badParams), block.timestamp + 1);
    }

    function test_modifyLiquidities_reverts_reentrancy() public {
        // Create a reentrant token and initialize the pool
        Currency reentrantToken = Currency.wrap(address(new ReentrantToken(lpm)));
        (currency0, currency1) = (Currency.unwrap(reentrantToken) < Currency.unwrap(currency1))
            ? (reentrantToken, currency1)
            : (currency1, reentrantToken);

        // Set up approvals for the reentrant token
        approvePosmCurrency(reentrantToken);
        (key, poolId) =
            initPool(currency0, currency1, IHooks(predictedPermissionedSwapRouterAddress), 3000, SQRT_PRICE_1_1);

        // Try to add liquidity at that range, but the token reenters posm
        PositionConfig memory config =
            PositionConfig({poolKey: key, tickLower: -int24(key.tickSpacing), tickUpper: int24(key.tickSpacing)});
        bytes memory calls = getMintEncoded(config, 1e18, ActionConstants.MSG_SENDER, "");

        // Permit2.transferFrom does not bubble the ContractLocked error and instead reverts with its own error
        vm.expectRevert("TRANSFER_FROM_FAILED");
        lpm.modifyLiquidities(calls, block.timestamp + 1);
    }

    function test_fuzz_mint_withLiquidityDelta(ModifyLiquidityParams memory params, uint160 sqrtPriceX96) public {
        bound(sqrtPriceX96, MIN_PRICE_LIMIT, MAX_PRICE_LIMIT);
        params = createFuzzyLiquidityParams(key, params, sqrtPriceX96);
        // liquidity is a uint
        uint256 liquidityToAdd =
            params.liquidityDelta < 0 ? uint256(-params.liquidityDelta) : uint256(params.liquidityDelta);
        PositionConfig memory config =
            PositionConfig({poolKey: key, tickLower: params.tickLower, tickUpper: params.tickUpper});

        uint256 balance0Before = currency0.balanceOfSelf();
        uint256 balance1Before = currency1.balanceOfSelf();
        uint256 balance0ManagerBefore = wrappedToken0.balanceOf(address(manager));
        uint256 balance1ManagerBefore = currency1.balanceOf(address(manager));
        uint256 tokenId = lpm.nextTokenId();
        mint(config, liquidityToAdd, ActionConstants.MSG_SENDER, ZERO_BYTES);
        uint256 balance0ManagerAfter = wrappedToken0.balanceOf(address(manager));
        uint256 balance1ManagerAfter = currency1.balanceOf(address(manager));

        assertEq(tokenId, 1);
        assertEq(lpm.nextTokenId(), 2);
        assertEq(IERC721(address(lpm)).ownerOf(tokenId), address(this));

        uint256 liquidity = lpm.getPositionLiquidity(tokenId);

        assertEq(liquidity, uint256(params.liquidityDelta));
        assertEq(
            balance0Before - currency0.balanceOfSelf(),
            balance0ManagerAfter - balance0ManagerBefore,
            "incorrect amount0"
        );
        assertEq(
            balance1Before - currency1.balanceOfSelf(),
            balance1ManagerAfter - balance1ManagerBefore,
            "incorrect amount1"
        );
    }

    function test_mint_exactTokenRatios() public {
        int24 tickLower = -int24(key.tickSpacing);
        int24 tickUpper = int24(key.tickSpacing);
        uint256 amount0Desired = 100e18;
        uint256 amount1Desired = 100e18;
        uint256 liquidityToAdd = LiquidityAmounts.getLiquidityForAmounts(
            SQRT_PRICE_1_1,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            amount0Desired,
            amount1Desired
        );
        PositionConfig memory config = PositionConfig({poolKey: key, tickLower: tickLower, tickUpper: tickUpper});
        uint256 balance0Before = currency0.balanceOfSelf();
        uint256 balance1Before = currency1.balanceOfSelf();
        uint256 balance0ManagerBefore = wrappedToken0.balanceOf(address(manager));

        uint256 tokenId = lpm.nextTokenId();
        mint(config, liquidityToAdd, ActionConstants.MSG_SENDER, ZERO_BYTES);
        uint256 balance0After = currency0.balanceOfSelf();
        uint256 balance1After = currency1.balanceOfSelf();
        uint256 balance0ManagerAfter = wrappedToken0.balanceOf(address(manager));
        assertEq(tokenId, 1);
        assertEq(IERC721(address(lpm)).ownerOf(1), address(this));
        assertEq(balance0Before - balance0After, balance0ManagerAfter - balance0ManagerBefore);
        assertEq(balance1Before - balance1After, amount1Desired);
    }

    function test_mint_toRecipient() public {
        int24 tickLower = -int24(key.tickSpacing);
        int24 tickUpper = int24(key.tickSpacing);
        uint256 amount0Desired = 100e18;
        uint256 amount1Desired = 100e18;
        uint256 liquidityToAdd = LiquidityAmounts.getLiquidityForAmounts(
            SQRT_PRICE_1_1,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            amount0Desired,
            amount1Desired
        );

        PositionConfig memory config = PositionConfig({poolKey: key, tickLower: tickLower, tickUpper: tickUpper});

        uint256 balance0Before = currency0.balanceOfSelf();
        uint256 balance1Before = currency1.balanceOfSelf();
        uint256 balance0ManagerBefore = wrappedToken0.balanceOf(address(manager));
        uint256 tokenId = lpm.nextTokenId();
        // mint to specific recipient, not using the recipient constants
        mint(config, liquidityToAdd, alice, ZERO_BYTES);

        uint256 balance0After = currency0.balanceOfSelf();
        uint256 balance1After = currency1.balanceOfSelf();
        uint256 balance0ManagerAfter = wrappedToken0.balanceOf(address(manager));
        assertEq(tokenId, 1);
        assertEq(IERC721(address(lpm)).ownerOf(1), alice);

        assertEq(balance0Before - balance0After, balance0ManagerAfter - balance0ManagerBefore);
        assertEq(balance1Before - balance1After, amount1Desired);
    }

    function test_fuzz_mint_recipient(ModifyLiquidityParams memory seedParams) public {
        ModifyLiquidityParams memory params = createFuzzyLiquidityParams(key, seedParams, SQRT_PRICE_1_1);
        uint256 liquidityToAdd =
            params.liquidityDelta < 0 ? uint256(-params.liquidityDelta) : uint256(params.liquidityDelta);

        PositionConfig memory config =
            PositionConfig({poolKey: key, tickLower: params.tickLower, tickUpper: params.tickUpper});

        uint256 tokenId = lpm.nextTokenId();
        uint256 balance0Before = currency0.balanceOfSelf();
        uint256 balance1Before = currency1.balanceOfSelf();
        uint256 balance0BeforeAlice = currency0.balanceOf(alice);
        uint256 balance1BeforeAlice = currency1.balanceOf(alice);
        uint256 balance0ManagerBefore = wrappedToken0.balanceOf(address(manager));
        uint256 balance1ManagerBefore = currency1.balanceOf(address(manager));
        mint(config, liquidityToAdd, alice, ZERO_BYTES);
        uint256 balance0ManagerAfter = wrappedToken0.balanceOf(address(manager));
        uint256 balance1ManagerAfter = currency1.balanceOf(address(manager));
        assertEq(tokenId, 1);
        assertEq(IERC721(address(lpm)).ownerOf(tokenId), alice);

        // alice was not the payer
        assertEq(balance0Before - currency0.balanceOfSelf(), balance0ManagerAfter - balance0ManagerBefore);
        assertEq(balance1Before - currency1.balanceOfSelf(), balance1ManagerAfter - balance1ManagerBefore);
        assertEq(currency0.balanceOf(alice), balance0BeforeAlice);
        assertEq(currency1.balanceOf(alice), balance1BeforeAlice);
    }

    /// @dev clear cannot be used on mint (negative delta)
    function test_fuzz_mint_clear_revert(ModifyLiquidityParams memory seedParams) public {
        ModifyLiquidityParams memory params = createFuzzyLiquidityParams(key, seedParams, SQRT_PRICE_1_1);
        uint256 liquidityToAdd =
            params.liquidityDelta < 0 ? uint256(-params.liquidityDelta) : uint256(params.liquidityDelta);

        PositionConfig memory config =
            PositionConfig({poolKey: key, tickLower: params.tickLower, tickUpper: params.tickUpper});

        Plan memory planner = Planner.init();
        planner.add(
            Actions.MINT_POSITION,
            abi.encode(
                config.poolKey,
                config.tickLower,
                config.tickUpper,
                liquidityToAdd,
                MAX_SLIPPAGE_INCREASE,
                MAX_SLIPPAGE_INCREASE,
                address(this),
                ZERO_BYTES
            )
        );
        planner.add(Actions.CLEAR_OR_TAKE, abi.encode(key.currency0, type(uint256).max));
        planner.add(Actions.CLEAR_OR_TAKE, abi.encode(key.currency1, type(uint256).max));
        bytes memory calls = planner.encode();

        Currency negativeDeltaCurrency = Currency.wrap(address(wrappedToken0));
        // because we're fuzzing the range, single-sided mint with currency1 means currency0Delta = 0 and currency1Delta < 0
        if (config.tickUpper <= 0) {
            negativeDeltaCurrency = currency1;
        }
        vm.expectRevert(abi.encodeWithSelector(DeltaResolver.DeltaNotPositive.selector, (negativeDeltaCurrency)));
        lpm.modifyLiquidities(calls, _deadline);
    }

    function test_mint_slippage_revertAmount0() public {
        PositionConfig memory config = PositionConfig({poolKey: key, tickLower: -120, tickUpper: 120});

        uint256 liquidity = 1e18;
        (uint256 amount0,) = LiquidityAmounts.getAmountsForLiquidity(
            SQRT_PRICE_1_1,
            TickMath.getSqrtPriceAtTick(config.tickLower),
            TickMath.getSqrtPriceAtTick(config.tickUpper),
            uint128(liquidity)
        );

        bytes memory calls =
            getMintEncoded(config, liquidity, 1 wei, MAX_SLIPPAGE_INCREASE, ActionConstants.MSG_SENDER, ZERO_BYTES);
        vm.expectRevert(abi.encodeWithSelector(SlippageCheck.MaximumAmountExceeded.selector, 1 wei, amount0 + 1));
        lpm.modifyLiquidities(calls, _deadline);
    }

    function test_mint_slippage_revertAmount1() public {
        PositionConfig memory config = PositionConfig({poolKey: key, tickLower: -120, tickUpper: 120});

        uint256 liquidity = 1e18;
        (, uint256 amount1) = LiquidityAmounts.getAmountsForLiquidity(
            SQRT_PRICE_1_1,
            TickMath.getSqrtPriceAtTick(config.tickLower),
            TickMath.getSqrtPriceAtTick(config.tickUpper),
            uint128(liquidity)
        );
        bytes memory calls =
            getMintEncoded(config, liquidity, MAX_SLIPPAGE_INCREASE, 1 wei, ActionConstants.MSG_SENDER, ZERO_BYTES);
        vm.expectRevert(abi.encodeWithSelector(SlippageCheck.MaximumAmountExceeded.selector, 1 wei, amount1 + 1));
        lpm.modifyLiquidities(calls, _deadline);
    }

    function test_mint_slippage_exactDoesNotRevert() public {
        PositionConfig memory config = PositionConfig({poolKey: key, tickLower: -120, tickUpper: 120});
        uint256 balance0ManagerBefore = wrappedToken0.balanceOf(address(manager));
        uint256 balance1ManagerBefore = currency1.balanceOf(address(manager));
        uint256 liquidity = 1e18;
        (uint256 amount0, uint256 amount1) = LiquidityAmounts.getAmountsForLiquidity(
            SQRT_PRICE_1_1,
            TickMath.getSqrtPriceAtTick(config.tickLower),
            TickMath.getSqrtPriceAtTick(config.tickUpper),
            uint128(liquidity)
        );
        assertEq(amount0, amount1); // symmetric liquidity
        uint128 slippage = uint128(amount0) + 1;

        bytes memory calls =
            getMintEncoded(config, liquidity, slippage, slippage, ActionConstants.MSG_SENDER, ZERO_BYTES);
        lpm.modifyLiquidities(calls, _deadline);
        uint256 balance0ManagerAfter = wrappedToken0.balanceOf(address(manager));
        uint256 balance1ManagerAfter = currency1.balanceOf(address(manager));
        assertEq(balance0ManagerAfter - balance0ManagerBefore, slippage);
        assertEq(balance1ManagerAfter - balance1ManagerBefore, slippage);
    }

    function test_mint_slippage_revert_swap() public {
        // swapping will cause a slippage revert
        PositionConfig memory config = PositionConfig({poolKey: key, tickLower: -120, tickUpper: 120});

        uint256 liquidity = 100e18;
        (uint256 amount0, uint256 amount1) = LiquidityAmounts.getAmountsForLiquidity(
            SQRT_PRICE_1_1,
            TickMath.getSqrtPriceAtTick(config.tickLower),
            TickMath.getSqrtPriceAtTick(config.tickUpper),
            uint128(liquidity)
        );
        assertEq(amount0, amount1); // symmetric liquidity
        uint128 slippage = uint128(amount0) + 1;
        bytes memory calls =
            getMintEncoded(config, liquidity, slippage, slippage, ActionConstants.MSG_SENDER, ZERO_BYTES);
        // swap to move the price and cause a slippage revert
        swap(key, true, -1e18);
        vm.expectRevert(
            abi.encodeWithSelector(SlippageCheck.MaximumAmountExceeded.selector, slippage, 1199947202932782783)
        );
        lpm.modifyLiquidities(calls, _deadline);
    }

    // Add a test to verify permissioned functionality works
    function test_permissioned_mint_allowed_user() public {
        // Alice is in the allowlist, so she should be able to mint
        vm.startPrank(alice);

        PositionConfig memory config = PositionConfig({poolKey: key, tickLower: -120, tickUpper: 120});
        uint256 liquidity = 1e18;

        uint256 tokenId = lpm.nextTokenId();
        mint(config, liquidity, ActionConstants.MSG_SENDER, ZERO_BYTES);

        assertEq(IERC721(address(lpm)).ownerOf(tokenId), alice);
        vm.stopPrank();
    }

    function test_permissioned_mint_disallowed_user() public {
        address unauthorizedUser = makeAddr("UNAUTHORIZED");

        // Add some tokens to unauthorized user
        MockERC20(Currency.unwrap(currency0)).mint(unauthorizedUser, 1000e18);
        MockERC20(Currency.unwrap(currency1)).mint(unauthorizedUser, 1000e18);

        vm.startPrank(unauthorizedUser);

        // Approve tokens for the position manager
        originalToken0.approve(address(permit2), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(permit2), type(uint256).max);
        permit2.approve(address(originalToken0), address(lpm), type(uint160).max, type(uint48).max);
        permit2.approve(Currency.unwrap(currency1), address(lpm), type(uint160).max, type(uint48).max);

        PositionConfig memory config = PositionConfig({poolKey: key, tickLower: -120, tickUpper: 120});
        uint256 liquidity = 1e18;

        // This should revert because the user is not in the allowlist
        vm.expectRevert();
        mint(config, liquidity, unauthorizedUser, ZERO_BYTES);

        vm.stopPrank();
    }

    function test_fuzz_burn_emptyPosition(ModifyLiquidityParams memory params) public {
        uint256 balance0Start = currency0.balanceOfSelf();
        uint256 balance1Start = currency1.balanceOfSelf();

        // create liquidity we can burn
        uint256 tokenId;
        (tokenId, params) = addFuzzyLiquidity(lpm, ActionConstants.MSG_SENDER, key, params, SQRT_PRICE_1_1, ZERO_BYTES);
        PositionConfig memory config =
            PositionConfig({poolKey: key, tickLower: params.tickLower, tickUpper: params.tickUpper});
        assertEq(tokenId, 1);
        assertEq(IERC721(address(lpm)).ownerOf(1), address(this));

        uint256 liquidity = lpm.getPositionLiquidity(tokenId);

        assertEq(liquidity, uint256(params.liquidityDelta));

        // burn liquidity
        uint256 balance0BeforeBurn = currency0.balanceOfSelf();
        uint256 balance1BeforeBurn = currency1.balanceOfSelf();
        uint256 balance0ManagerBefore = wrappedToken0.balanceOf(address(manager));
        uint256 balance1ManagerBefore = currency1.balanceOf(address(manager));
        decreaseLiquidity(tokenId, config, liquidity, ZERO_BYTES);
        uint256 balance0ManagerAfter = wrappedToken0.balanceOf(address(manager));
        uint256 balance1ManagerAfter = currency1.balanceOf(address(manager));
        liquidity = lpm.getPositionLiquidity(tokenId);

        assertEq(liquidity, 0);
        // 721 will revert if the token does not exist
        assertEq(currency0.balanceOfSelf(), balance0BeforeBurn + balance0ManagerBefore - balance0ManagerAfter);
        assertEq(currency1.balanceOfSelf(), balance1BeforeBurn + balance1ManagerBefore - balance1ManagerAfter);

        IERC721(address(lpm)).ownerOf(1);
        // no tokens were lost, TODO: fuzzer showing off by 1 sometimes
        // Potentially because we round down in core. I believe this is known in V3. But let's check!
        assertApproxEqAbs(currency0.balanceOfSelf(), balance0Start, 1 wei);
        assertApproxEqAbs(currency1.balanceOfSelf(), balance1Start, 1 wei);
    }

    function test_initialize() public {
        // initialize a new pool and add liquidity
        key = PoolKey({currency0: currency0, currency1: currency1, fee: 0, tickSpacing: 10, hooks: IHooks(address(0))});
        lpm.initializePool(key, SQRT_PRICE_1_1);

        (uint160 sqrtPriceX96, int24 tick, uint24 protocolFee, uint24 lpFee) = manager.getSlot0(key.toId());
        assertEq(sqrtPriceX96, SQRT_PRICE_1_1);
        assertEq(tick, 0);
        assertEq(protocolFee, 0);
        assertEq(lpFee, key.fee);
    }

    function test_fuzz_initialize(uint160 sqrtPrice, uint24 fee) public {
        sqrtPrice =
            uint160(bound(sqrtPrice, TickMath.MIN_SQRT_PRICE, TickMath.MAX_SQRT_PRICE_MINUS_MIN_SQRT_PRICE_MINUS_ONE));
        fee = uint24(bound(fee, 0, LPFeeLibrary.MAX_LP_FEE));
        key =
            PoolKey({currency0: currency0, currency1: currency1, fee: fee, tickSpacing: 10, hooks: IHooks(address(0))});
        lpm.initializePool(key, sqrtPrice);

        (uint160 sqrtPriceX96, int24 tick, uint24 protocolFee, uint24 lpFee) = manager.getSlot0(key.toId());
        assertEq(sqrtPriceX96, sqrtPrice);
        assertEq(tick, TickMath.getTickAtSqrtPrice(sqrtPrice));
        assertEq(protocolFee, 0);
        assertEq(lpFee, fee);
    }
}
