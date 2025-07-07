// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "forge-std/Test.sol";
import {IERC721} from "forge-std/interfaces/IERC721.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FixedPointMathLib} from "solmate/src/utils/FixedPointMathLib.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {IPositionManager} from "../../../src/interfaces/IPositionManager.sol";
import {Actions} from "../../../src/libraries/Actions.sol";
import {DeltaResolver} from "../../../src/base/DeltaResolver.sol";
import {PositionConfig} from "test/shared/PositionConfig.sol";
import {SlippageCheck} from "../../../src/libraries/SlippageCheck.sol";
import {BaseActionsRouter} from "../../../src/base/BaseActionsRouter.sol";
import {ActionConstants} from "../../../src/libraries/ActionConstants.sol";
import {LiquidityFuzzers} from "../../shared/fuzz/LiquidityFuzzers.sol";
import {Planner, Plan} from "../../shared/Planner.sol";
import {PermissionedPosmTestSetup, BalanceInfo} from "./shared/PermissionedPosmTestSetup.sol";
import {ReentrantToken} from "../../mocks/ReentrantToken.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {MockAllowlistChecker, MockPermissionedToken} from "./PermissionedPoolsBase.sol";
import {WrappedPermissionedToken, IERC20} from "../../../src/hooks/permissionedPools/WrappedPermissionedToken.sol";

contract PermissionedPositionManagerTest is Test, PermissionedPosmTestSetup, LiquidityFuzzers {
    using FixedPointMathLib for uint256;
    using StateLibrary for IPoolManager;

    PoolId public poolId;
    PoolId public poolIdFake;

    // Permissioned components
    MockAllowlistChecker public mockAllowListChecker;
    WrappedPermissionedToken public wrappedToken0;
    WrappedPermissionedToken public wrappedToken2;
    MockERC20 public originalToken0;
    MockERC20 public originalToken2;
    IPositionManager public secondaryPosm;
    IPositionManager public tertiaryPosm;

    PoolKey public key0;
    PoolKey public key1;
    PoolKey public key2;
    PoolKey public keyFake0;
    PoolKey public keyFake1;
    PoolKey public keyFake2;

    // Test Users
    address public alice = makeAddr("ALICE");
    address public unauthorizedUser = makeAddr("UNAUTHORIZED");

    function setUp() public {
        permit2 = IAllowanceTransfer(deployPermit2());

        deployFreshManagerAndRoutersPermissioned(address(permit2), address(_WETH9));
        (currency0, currency1) = deployMintAndApprove2Currencies(true, false);
        currency2 = deployMintAndApproveCurrency(true);

        setUpPosms();
        setupPermissionedComponents();
        setupPool();

        // set up approvals for alice
        seedBalance(alice);
        approvePosmFor(alice);
    }

    function setUpPosms() internal {
        deployAndApprovePosm(
            manager, address(wrappedTokenFactory), address(permissionedHooks), keccak256("permissionedPosm")
        );

        // alternate position manager using different hooks
        secondaryPosm = deployAndApprovePosmOnly(
            manager, address(wrappedTokenFactory), address(secondaryPermissionedHooks), keccak256("secondaryPosm")
        );

        // alternate position manager using the same hooks
        tertiaryPosm = deployAndApprovePosmOnly(
            manager, address(wrappedTokenFactory), address(permissionedHooks), keccak256("tertiaryPosm")
        );
    }

    function setupPool() internal {
        (key0, poolId) =
            initPool(Currency.wrap(address(wrappedToken0)), currency1, permissionedHooks, 3000, SQRT_PRICE_1_1);
        (key1, poolId) =
            initPool(currency1, Currency.wrap(address(wrappedToken2)), permissionedHooks, 3000, SQRT_PRICE_1_1);
        (key2, poolId) = initPool(
            Currency.wrap(address(wrappedToken0)),
            Currency.wrap(address(wrappedToken2)),
            permissionedHooks,
            3000,
            SQRT_PRICE_1_1
        );
        (keyFake0, poolId) =
            initPool(Currency.wrap(address(wrappedToken0)), currency1, secondaryPermissionedHooks, 3000, SQRT_PRICE_1_1);
        (keyFake1, poolId) =
            initPool(currency1, Currency.wrap(address(wrappedToken2)), secondaryPermissionedHooks, 3000, SQRT_PRICE_1_1);
        (keyFake2, poolId) = initPool(
            Currency.wrap(address(wrappedToken0)),
            Currency.wrap(address(wrappedToken2)),
            secondaryPermissionedHooks,
            3000,
            SQRT_PRICE_1_1
        );
    }

    function setupPermissionedComponents() internal {
        mockAllowListChecker = new MockAllowlistChecker(MockPermissionedToken(Currency.unwrap(currency0)));
        setUpCurrencyZero();
        setUpCurrencyTwo();
    }

    function setUpCurrencyZero() internal {
        setUpAllowlist(currency0);
        originalToken0 = MockERC20(Currency.unwrap(currency0));
        // ensure expected ordering
        while (true) {
            wrappedToken0 = WrappedPermissionedToken(
                wrappedTokenFactory.createWrappedPermissionedToken(
                    IERC20(address(originalToken0)), address(this), mockAllowListChecker
                )
            );
            if (address(wrappedToken0) < Currency.unwrap(currency1)) {
                break;
            }
        }
        setUpWrappedToken(wrappedToken0, currency0);
    }

    function setUpCurrencyTwo() internal {
        setUpAllowlist(currency2);
        originalToken2 = MockERC20(Currency.unwrap(currency2));

        // ensure expected ordering
        while (true) {
            wrappedToken2 = WrappedPermissionedToken(
                wrappedTokenFactory.createWrappedPermissionedToken(
                    IERC20(address(originalToken2)), address(this), mockAllowListChecker
                )
            );
            if (Currency.unwrap(currency1) < address(wrappedToken2)) {
                break;
            }
        }
        setUpWrappedToken(wrappedToken2, currency2);
    }

    function setUpAllowlist(Currency currency) internal {
        MockPermissionedToken(Currency.unwrap(currency)).setAllowlist(address(this), true);
        MockPermissionedToken(Currency.unwrap(currency)).setAllowlist(alice, true);
        MockPermissionedToken(Currency.unwrap(currency)).setAllowlist(address(lpm), true);
        MockPermissionedToken(Currency.unwrap(currency)).setAllowlist(address(secondaryPosm), true);
        MockPermissionedToken(Currency.unwrap(currency)).setAllowlist(address(wrappedTokenFactory), true);
        MockPermissionedToken(Currency.unwrap(currency)).setAllowlist(address(lpm), true);
        MockPermissionedToken(Currency.unwrap(currency)).setAllowlist(address(manager), true);
        MockPermissionedToken(Currency.unwrap(currency)).setAllowlist(address(permissionedSwapRouter), true);
        MockPermissionedToken(Currency.unwrap(currency2)).setAllowlist(address(permissionedHooks), true);
    }

    function setUpWrappedToken(WrappedPermissionedToken wrappedToken, Currency currency) internal {
        wrappedToPermissioned[Currency.wrap(address(wrappedToken))] = currency;

        MockPermissionedToken(Currency.unwrap(currency)).mint(address(this), 1000 ether);
        MockPermissionedToken(Currency.unwrap(currency)).setAllowlist(address(wrappedToken), true);

        // wrapped token contract must have a non-zero balance of the permissioned token
        currency.transfer(address(wrappedToken), 1);

        wrappedToken.updateAllowedWrapper(address(manager), true);
        wrappedToken.updateAllowedWrapper(address(secondaryPosm), true);
        wrappedToken.updateAllowedWrapper(address(lpm), true);
        wrappedToken.updateAllowedWrapper(address(permissionedSwapRouter), true);

        wrappedTokenFactory.verifyWrappedToken(address(wrappedToken));
    }

    function test_modifyLiquidities_reverts_deadlinePassed() public {
        _test_modifyLiquidities_reverts_deadlinePassed(key0);
        _test_modifyLiquidities_reverts_deadlinePassed(key1);
        _test_modifyLiquidities_reverts_deadlinePassed(key2);
    }

    function _test_modifyLiquidities_reverts_deadlinePassed(PoolKey memory key) internal {
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
        PoolKey memory key;

        // Create a reentrant token and initialize the pool
        Currency reentrantToken = Currency.wrap(address(new ReentrantToken(lpm)));
        (currency0, currency1) = (Currency.unwrap(reentrantToken) < Currency.unwrap(currency1))
            ? (reentrantToken, currency1)
            : (currency1, reentrantToken);

        // Set up approvals for the reentrant token
        approvePosmCurrency(reentrantToken);
        (key, poolId) = initPool(currency0, currency1, permissionedHooks, 3000, SQRT_PRICE_1_1);

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

        _test_fuzz_mint_withLiquidityDelta(key0, params, sqrtPriceX96);
        _test_fuzz_mint_withLiquidityDelta(key1, params, sqrtPriceX96);
        _test_fuzz_mint_withLiquidityDelta(key2, params, sqrtPriceX96);
    }

    function _test_fuzz_mint_withLiquidityDelta(
        PoolKey memory key,
        ModifyLiquidityParams memory params,
        uint160 sqrtPriceX96
    ) internal {
        params = createFuzzyLiquidityParams(key, params, sqrtPriceX96);
        PositionConfig memory config =
            PositionConfig({poolKey: key, tickLower: params.tickLower, tickUpper: params.tickUpper});

        // liquidity is a uint
        uint256 liquidityToAdd =
            params.liquidityDelta < 0 ? uint256(-params.liquidityDelta) : uint256(params.liquidityDelta);

        uint256 balance0Before = getPermissionedCurrency(key.currency0).balanceOfSelf();
        uint256 balance1Before = getPermissionedCurrency(key.currency1).balanceOfSelf();
        uint256 balance0ManagerBefore = key.currency0.balanceOf(address(manager));
        uint256 balance1ManagerBefore = key.currency1.balanceOf(address(manager));
        uint256 tokenId = lpm.nextTokenId();

        mint(config, liquidityToAdd, ActionConstants.MSG_SENDER, ZERO_BYTES);

        uint256 balance0ManagerAfter = key.currency0.balanceOf(address(manager));
        uint256 balance1ManagerAfter = key.currency1.balanceOf(address(manager));
        uint256 liquidity = lpm.getPositionLiquidity(tokenId);

        assertEq(tokenId, lpm.nextTokenId() - 1);
        assertEq(IERC721(address(lpm)).ownerOf(tokenId), address(this));
        assertEq(liquidity, uint256(params.liquidityDelta));
        assertEq(
            balance0Before - getPermissionedCurrency(key.currency0).balanceOfSelf(),
            balance0ManagerAfter - balance0ManagerBefore,
            "incorrect amount0"
        );
        assertEq(
            balance1Before - getPermissionedCurrency(key.currency1).balanceOfSelf(),
            balance1ManagerAfter - balance1ManagerBefore,
            "incorrect amount1"
        );
    }

    function test_mint_exactTokenRatios() public {
        _test_mint_exactTokenRatios(key0);
        _test_mint_exactTokenRatios(key1);
        _test_mint_exactTokenRatios(key2);
    }

    function _test_mint_exactTokenRatios(PoolKey memory key) internal {
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

        uint256 balance0Before = getPermissionedCurrency(key.currency0).balanceOfSelf();
        uint256 balance1Before = getPermissionedCurrency(key.currency1).balanceOfSelf();
        uint256 balance0ManagerBefore = key.currency0.balanceOf(address(manager));
        uint256 tokenId = lpm.nextTokenId();

        mint(config, liquidityToAdd, ActionConstants.MSG_SENDER, ZERO_BYTES);

        uint256 balance0After = getPermissionedCurrency(key.currency0).balanceOfSelf();
        uint256 balance1After = getPermissionedCurrency(key.currency1).balanceOfSelf();
        uint256 balance0ManagerAfter = key.currency0.balanceOf(address(manager));
        assertEq(tokenId, lpm.nextTokenId() - 1);
        assertEq(IERC721(address(lpm)).ownerOf(tokenId), address(this));
        assertEq(balance0Before - balance0After, balance0ManagerAfter - balance0ManagerBefore);
        assertEq(balance1Before - balance1After, amount1Desired);
    }

    function test_mint_toRecipient() public {
        _test_mint_toRecipient(key0);
        _test_mint_toRecipient(key1);
        _test_mint_toRecipient(key2);
    }

    function _test_mint_toRecipient(PoolKey memory key) internal {
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

        uint256 tokenId = lpm.nextTokenId();

        BalanceInfo memory balanceInfoBefore = getBalanceInfoSelfAndManager(key);

        // mint to specific recipient, alice, not using the recipient constants
        mint(config, liquidityToAdd, alice, ZERO_BYTES);

        BalanceInfo memory balanceInfoAfter = getBalanceInfoSelfAndManager(key);

        assertEq(tokenId, lpm.nextTokenId() - 1);
        assertEq(IERC721(address(lpm)).ownerOf(tokenId), alice);
        assertEq(
            balanceInfoBefore.balance0 - balanceInfoAfter.balance0,
            balanceInfoAfter.balance0Manager - balanceInfoBefore.balance0Manager
        );
        assertEq(
            balanceInfoBefore.balance1 - balanceInfoAfter.balance1,
            balanceInfoAfter.balance1Manager - balanceInfoBefore.balance1Manager
        );
        assertEq(balanceInfoBefore.balance0 - balanceInfoAfter.balance0, amount0Desired);
        assertEq(balanceInfoBefore.balance1 - balanceInfoAfter.balance1, amount1Desired);
    }

    function test_fuzz_mint_recipient(ModifyLiquidityParams memory seedParams) public {
        _test_fuzz_mint_recipient(key0, seedParams);
        _test_fuzz_mint_recipient(key1, seedParams);
        _test_fuzz_mint_recipient(key2, seedParams);
    }

    function _test_fuzz_mint_recipient(PoolKey memory key, ModifyLiquidityParams memory seedParams) internal {
        ModifyLiquidityParams memory params = createFuzzyLiquidityParams(key, seedParams, SQRT_PRICE_1_1);
        PositionConfig memory config =
            PositionConfig({poolKey: key, tickLower: params.tickLower, tickUpper: params.tickUpper});

        uint256 liquidityToAdd =
            params.liquidityDelta < 0 ? uint256(-params.liquidityDelta) : uint256(params.liquidityDelta);

        Currency currency0_ = getPermissionedCurrency(key.currency0);
        Currency currency1_ = getPermissionedCurrency(key.currency1);
        Currency currency0wrapped = key.currency0;
        Currency currency1wrapped = key.currency1;
        uint256 tokenId = lpm.nextTokenId();
        uint256 balance0Before = currency0_.balanceOfSelf();
        uint256 balance1Before = currency1_.balanceOfSelf();
        uint256 balance0BeforeAlice = currency0_.balanceOf(alice);
        uint256 balance1BeforeAlice = currency1_.balanceOf(alice);
        uint256 balance0ManagerBefore = currency0wrapped.balanceOf(address(manager));
        uint256 balance1ManagerBefore = currency1wrapped.balanceOf(address(manager));

        mint(config, liquidityToAdd, alice, ZERO_BYTES);

        uint256 balance0ManagerAfter = currency0wrapped.balanceOf(address(manager));
        uint256 balance1ManagerAfter = currency1wrapped.balanceOf(address(manager));

        // alice was not the payer
        assertEq(tokenId, lpm.nextTokenId() - 1);
        assertEq(IERC721(address(lpm)).ownerOf(tokenId), alice);
        assertEq(balance0Before - currency0_.balanceOfSelf(), balance0ManagerAfter - balance0ManagerBefore);
        assertEq(balance1Before - currency1_.balanceOfSelf(), balance1ManagerAfter - balance1ManagerBefore);
        assertEq(currency0_.balanceOf(alice), balance0BeforeAlice);
        assertEq(currency1_.balanceOf(alice), balance1BeforeAlice);
    }

    /// @dev clear cannot be used on mint (negative delta)
    function test_fuzz_mint_clear_revert(ModifyLiquidityParams memory seedParams) public {
        _test_fuzz_mint_clear_revert(key0, seedParams);
        _test_fuzz_mint_clear_revert(key1, seedParams);
        _test_fuzz_mint_clear_revert(key2, seedParams);
    }

    function _test_fuzz_mint_clear_revert(PoolKey memory key, ModifyLiquidityParams memory seedParams) internal {
        ModifyLiquidityParams memory params = createFuzzyLiquidityParams(key, seedParams, SQRT_PRICE_1_1);
        PositionConfig memory config =
            PositionConfig({poolKey: key, tickLower: params.tickLower, tickUpper: params.tickUpper});

        uint256 liquidityToAdd =
            params.liquidityDelta < 0 ? uint256(-params.liquidityDelta) : uint256(params.liquidityDelta);

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

        Currency negativeDeltaCurrency = key.currency0;
        // because we're fuzzing the range, single-sided mint with currency1 means currency0Delta = 0 and currency1Delta < 0
        if (config.tickUpper <= 0) {
            negativeDeltaCurrency = key.currency1;
        }

        vm.expectRevert(abi.encodeWithSelector(DeltaResolver.DeltaNotPositive.selector, (negativeDeltaCurrency)));
        lpm.modifyLiquidities(calls, _deadline);
    }

    function test_mint_slippage_revertAmount0() public {
        _test_mint_slippage_revertAmount0(key0);
        _test_mint_slippage_revertAmount0(key1);
        _test_mint_slippage_revertAmount0(key2);
    }

    function _test_mint_slippage_revertAmount0(PoolKey memory key) internal {
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
        _test_mint_slippage_revertAmount1(key0);
        _test_mint_slippage_revertAmount1(key1);
        _test_mint_slippage_revertAmount1(key2);
    }

    function _test_mint_slippage_revertAmount1(PoolKey memory key) internal {
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
        _test_mint_slippage_exactDoesNotRevert(key0);
        _test_mint_slippage_exactDoesNotRevert(key1);
        _test_mint_slippage_exactDoesNotRevert(key2);
    }

    function _test_mint_slippage_exactDoesNotRevert(PoolKey memory key) internal {
        PositionConfig memory config = PositionConfig({poolKey: key, tickLower: -120, tickUpper: 120});

        uint256 liquidity = 1e18;
        (uint256 amount0, uint256 amount1) = LiquidityAmounts.getAmountsForLiquidity(
            SQRT_PRICE_1_1,
            TickMath.getSqrtPriceAtTick(config.tickLower),
            TickMath.getSqrtPriceAtTick(config.tickUpper),
            uint128(liquidity)
        );
        uint128 slippage = uint128(amount0) + 1;

        uint256 balance0ManagerBefore = key.currency0.balanceOf(address(manager));
        uint256 balance1ManagerBefore = key.currency1.balanceOf(address(manager));

        assertEq(amount0, amount1); // symmetric liquidity

        bytes memory calls =
            getMintEncoded(config, liquidity, slippage, slippage, ActionConstants.MSG_SENDER, ZERO_BYTES);

        lpm.modifyLiquidities(calls, _deadline);

        uint256 balance0ManagerAfter = key.currency0.balanceOf(address(manager));
        uint256 balance1ManagerAfter = key.currency1.balanceOf(address(manager));

        assertEq(balance0ManagerAfter - balance0ManagerBefore, slippage);
        assertEq(balance1ManagerAfter - balance1ManagerBefore, slippage);
    }

    function test_mint_slippage_revert_swap() public {
        _test_mint_slippage_revert_swap(key0);
        _test_mint_slippage_revert_swap(key1);
        _test_mint_slippage_revert_swap(key2);
    }

    function _test_mint_slippage_revert_swap(PoolKey memory key) internal {
        // swapping will cause a slippage revert
        PositionConfig memory config = PositionConfig({poolKey: key, tickLower: -120, tickUpper: 120});

        uint256 liquidity = 100e18;
        (uint256 amount0, uint256 amount1) = LiquidityAmounts.getAmountsForLiquidity(
            SQRT_PRICE_1_1,
            TickMath.getSqrtPriceAtTick(config.tickLower),
            TickMath.getSqrtPriceAtTick(config.tickUpper),
            uint128(liquidity)
        );
        uint128 slippage = uint128(amount0) + 1;

        assertEq(amount0, amount1); // symmetric liquidity

        bytes memory calls =
            getMintEncoded(config, liquidity, slippage, slippage, ActionConstants.MSG_SENDER, ZERO_BYTES);

        // swap to move the price and cause a slippage revert
        swap(key, true, -1e18);

        vm.expectRevert(
            abi.encodeWithSelector(SlippageCheck.MaximumAmountExceeded.selector, slippage, 1199947202932782783)
        );
        lpm.modifyLiquidities(calls, _deadline);
    }

    function test_permissioned_mint_allowed_user() public {
        _test_permissioned_mint_allowed_user(key0);
        _test_permissioned_mint_allowed_user(key1);
        _test_permissioned_mint_allowed_user(key2);
    }

    function _test_permissioned_mint_allowed_user(PoolKey memory key) internal {
        PositionConfig memory config = PositionConfig({poolKey: key, tickLower: -120, tickUpper: 120});

        uint256 liquidity = 1e18;
        uint256 tokenId = lpm.nextTokenId();

        // Alice is in the allowlist, so she should be able to mint
        vm.prank(alice);
        mint(config, liquidity, ActionConstants.MSG_SENDER, ZERO_BYTES);

        assertEq(IERC721(address(lpm)).ownerOf(tokenId), alice);
    }

    function test_permissioned_mint_alternate_posm_reverts() public {
        // secondary posm uses different hooks contract
        _test_permissioned_mint_alternate_posm_reverts(key0, secondaryPosm);
        _test_permissioned_mint_alternate_posm_reverts(key1, secondaryPosm);
        _test_permissioned_mint_alternate_posm_reverts(key2, secondaryPosm);

        // tertiary posm uses the same hooks contract
        _test_permissioned_mint_alternate_posm_reverts(key0, tertiaryPosm);
        _test_permissioned_mint_alternate_posm_reverts(key1, tertiaryPosm);
        _test_permissioned_mint_alternate_posm_reverts(key2, tertiaryPosm);
    }

    function _test_permissioned_mint_alternate_posm_reverts(PoolKey memory key, IPositionManager posm) internal {
        PositionConfig memory config = PositionConfig({poolKey: key, tickLower: -120, tickUpper: 120});

        uint256 liquidity = 1e18;

        // we don't use the helper, so we can choose which position manager to use
        bytes memory calls = getMintEncoded(config, liquidity, ActionConstants.MSG_SENDER, ZERO_BYTES);

        vm.prank(alice);
        vm.expectRevert();
        posm.modifyLiquidities(calls, block.timestamp + 1);
    }

    function test_permissioned_mint_disallowed_user_reverts() public {
        _test_permissioned_mint_disallowed_user_reverts(key0);
        _test_permissioned_mint_disallowed_user_reverts(key1);
        _test_permissioned_mint_disallowed_user_reverts(key2);
    }

    function _test_permissioned_mint_disallowed_user_reverts(PoolKey memory key) internal {
        PositionConfig memory config = PositionConfig({poolKey: key, tickLower: -120, tickUpper: 120});

        uint256 liquidity = 1e18;

        // Add some tokens to unauthorized user
        MockPermissionedToken(Currency.unwrap(currency0)).setAllowlist(unauthorizedUser, true);
        MockPermissionedToken(Currency.unwrap(currency0)).mint(unauthorizedUser, 1000e18);
        MockPermissionedToken(Currency.unwrap(currency0)).setAllowlist(unauthorizedUser, false);
        MockERC20(Currency.unwrap(currency1)).mint(unauthorizedUser, 1000e18);

        vm.startPrank(unauthorizedUser);

        // Approve tokens for the position manager
        originalToken0.approve(address(permit2), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(permit2), type(uint256).max);
        permit2.approve(address(originalToken0), address(lpm), type(uint160).max, type(uint48).max);
        permit2.approve(Currency.unwrap(currency1), address(lpm), type(uint160).max, type(uint48).max);

        // This should revert because the user is not in the allowlist
        vm.expectRevert();
        mint(config, liquidity, unauthorizedUser, ZERO_BYTES);
        vm.stopPrank();
    }

    function test_permissioned_mint_increase_allowed_user() public {
        _test_permissioned_mint_increase_allowed_user(key0);
        _test_permissioned_mint_increase_allowed_user(key1);
        _test_permissioned_mint_increase_allowed_user(key2);
    }

    function _test_permissioned_mint_increase_allowed_user(PoolKey memory key) internal {
        PositionConfig memory config = PositionConfig({poolKey: key, tickLower: -120, tickUpper: 120});

        uint256 liquidity = 1e18;
        uint256 tokenId = lpm.nextTokenId();

        vm.startPrank(alice);

        // add initial liquidity
        mint(config, liquidity, ActionConstants.MSG_SENDER, ZERO_BYTES);

        assertEq(IERC721(address(lpm)).ownerOf(tokenId), alice);

        tokenId = lpm.nextTokenId();

        // Increase liquidity
        mint(config, liquidity, ActionConstants.MSG_SENDER, ZERO_BYTES);
        vm.stopPrank();

        assertEq(IERC721(address(lpm)).ownerOf(tokenId), alice);
    }

    function test_permissioned_mint_increase_disallowed_user_reverts() public {
        _test_permissioned_mint_increase_disallowed_user_reverts(key0);
        _test_permissioned_mint_increase_disallowed_user_reverts(key1);
        _test_permissioned_mint_increase_disallowed_user_reverts(key2);
    }

    function _test_permissioned_mint_increase_disallowed_user_reverts(PoolKey memory key) internal {
        PositionConfig memory config = PositionConfig({poolKey: key, tickLower: -120, tickUpper: 120});

        uint256 liquidity = 1e17;
        uint256 tokenId = lpm.nextTokenId();

        vm.startPrank(alice);

        // add initial liquidity
        mint(config, liquidity, ActionConstants.MSG_SENDER, ZERO_BYTES);

        assertEq(IERC721(address(lpm)).ownerOf(tokenId), alice);

        MockPermissionedToken(Currency.unwrap(currency0)).setAllowlist(alice, false);
        MockPermissionedToken(Currency.unwrap(currency2)).setAllowlist(alice, false);

        tokenId = lpm.nextTokenId();

        // Increasing liquidity should revert because the user is no longer in the allowlist
        vm.expectRevert();
        mint(config, liquidity, ActionConstants.MSG_SENDER, ZERO_BYTES);
        vm.stopPrank();

        MockPermissionedToken(Currency.unwrap(currency0)).setAllowlist(alice, true);
        MockPermissionedToken(Currency.unwrap(currency2)).setAllowlist(alice, true);
    }

    function test_unpermissioned_sided_mint_disallowed_user_reverts() public {
        _test_unpermissioned_sided_mint_disallowed_user_reverts(key0, false);
        _test_unpermissioned_sided_mint_disallowed_user_reverts(key1, true);
        // key2 has no unpermissioned side
    }

    function _test_unpermissioned_sided_mint_disallowed_user_reverts(PoolKey memory key, bool useZero) internal {
        PositionConfig memory config;
        Currency currencyUnpermissioned;

        uint256 liquidity = 1e18;

        if (useZero) {
            currencyUnpermissioned = getPermissionedCurrency(key.currency0);
            config = PositionConfig({poolKey: key, tickLower: -180, tickUpper: -60});
        } else {
            currencyUnpermissioned = getPermissionedCurrency(key.currency1);
            config = PositionConfig({poolKey: key, tickLower: 60, tickUpper: 180});
        }

        // Add some tokens to unauthorized user
        MockERC20(Currency.unwrap(currencyUnpermissioned)).mint(unauthorizedUser, 1000e18);

        vm.startPrank(unauthorizedUser);

        // Approve tokens for the position manager and permit2
        MockERC20(Currency.unwrap(currencyUnpermissioned)).approve(address(permit2), type(uint256).max);
        permit2.approve(Currency.unwrap(currencyUnpermissioned), address(lpm), type(uint160).max, type(uint48).max);

        // This should revert because the user is not in the allowlist
        vm.expectRevert();
        mint(config, liquidity, unauthorizedUser, ZERO_BYTES);
        vm.stopPrank();
    }

    function test_unpermissioned_sided_mint_allowed_user() public {
        _test_unpermissioned_sided_mint_allowed_user(key0, false);
        _test_unpermissioned_sided_mint_allowed_user(key1, true);
        // key2 has no unpermissioned side
    }

    function _test_unpermissioned_sided_mint_allowed_user(PoolKey memory key, bool useZero) internal {
        PositionConfig memory config;
        Currency currencyPermissioned;

        uint256 liquidity = 1e18;
        uint256 tokenId = lpm.nextTokenId();

        if (useZero) {
            currencyPermissioned = getPermissionedCurrency(key.currency0);
            config = PositionConfig({poolKey: key, tickLower: -180, tickUpper: -60});
        } else {
            currencyPermissioned = getPermissionedCurrency(key.currency1);
            config = PositionConfig({poolKey: key, tickLower: 60, tickUpper: 180});
        }

        vm.startPrank(alice);

        // Approve tokens for the position manager and permit2
        MockERC20(Currency.unwrap(currencyPermissioned)).approve(address(permit2), type(uint256).max);
        permit2.approve(Currency.unwrap(currencyPermissioned), address(lpm), type(uint160).max, type(uint48).max);

        mint(config, liquidity, alice, ZERO_BYTES);
        vm.stopPrank();

        assertEq(IERC721(address(lpm)).ownerOf(tokenId), alice);
    }

    function test_permissioned_sided_mint_disallowed_user_reverts() public {
        _test_permissioned_sided_mint_disallowed_user_reverts(key0, true);
        _test_permissioned_sided_mint_disallowed_user_reverts(key1, false);
        _test_permissioned_sided_mint_disallowed_user_reverts(key2, true);
    }

    function _test_permissioned_sided_mint_disallowed_user_reverts(PoolKey memory key, bool useZero) internal {
        PositionConfig memory config;
        Currency currencyPermissioned;

        uint256 liquidity = 1e18;

        if (useZero) {
            currencyPermissioned = getPermissionedCurrency(key.currency0);
            config = PositionConfig({poolKey: key, tickLower: -180, tickUpper: -60});
        } else {
            currencyPermissioned = getPermissionedCurrency(key.currency1);
            config = PositionConfig({poolKey: key, tickLower: 60, tickUpper: 180});
        }

        // Add some tokens to unauthorized user
        MockPermissionedToken(Currency.unwrap(currencyPermissioned)).setAllowlist(unauthorizedUser, true);
        MockPermissionedToken(Currency.unwrap(currencyPermissioned)).mint(unauthorizedUser, 1000e18);
        MockPermissionedToken(Currency.unwrap(currencyPermissioned)).setAllowlist(unauthorizedUser, false);

        vm.startPrank(unauthorizedUser);

        // Approve tokens for the position manager and permit2
        MockERC20(Currency.unwrap(currencyPermissioned)).approve(address(permit2), type(uint256).max);
        permit2.approve(Currency.unwrap(currencyPermissioned), address(lpm), type(uint160).max, type(uint48).max);

        // This should revert because the user is not in the allowlist
        vm.expectRevert();
        mint(config, liquidity, unauthorizedUser, ZERO_BYTES);
        vm.stopPrank();
    }

    function test_permissioned_single_sided_mint_allowed_user() public {
        _test_permissioned_sided_mint_allowed_user(key0, true);
        _test_permissioned_sided_mint_allowed_user(key1, false);
        _test_permissioned_sided_mint_allowed_user(key2, true);
    }

    function _test_permissioned_sided_mint_allowed_user(PoolKey memory key, bool useZero) internal {
        PositionConfig memory config;

        uint256 liquidity = 1e18;
        uint256 tokenId = lpm.nextTokenId();

        if (useZero) {
            config = PositionConfig({poolKey: key, tickLower: -180, tickUpper: -60});
        } else {
            config = PositionConfig({poolKey: key, tickLower: 60, tickUpper: 180});
        }

        vm.prank(alice);
        mint(config, liquidity, alice, ZERO_BYTES);

        assertEq(IERC721(address(lpm)).ownerOf(tokenId), alice);
    }

    function test_fuzz_burn_emptyPosition(ModifyLiquidityParams memory params) public {
        _test_fuzz_burn_emptyPosition(key0, params);
        _test_fuzz_burn_emptyPosition(key1, params);
        _test_fuzz_burn_emptyPosition(key2, params);
    }

    function _test_fuzz_burn_emptyPosition(PoolKey memory key, ModifyLiquidityParams memory params) internal {
        uint256 balance0Start = key.currency0.balanceOfSelf();
        uint256 balance1Start = key.currency1.balanceOfSelf();
        uint256 tokenId;

        // create liquidity we can burn
        (tokenId, params) = addFuzzyLiquidity(lpm, ActionConstants.MSG_SENDER, key, params, SQRT_PRICE_1_1, ZERO_BYTES);
        PositionConfig memory config =
            PositionConfig({poolKey: key, tickLower: params.tickLower, tickUpper: params.tickUpper});
        assertEq(tokenId, lpm.nextTokenId() - 1);
        assertEq(IERC721(address(lpm)).ownerOf(1), address(this));

        uint256 liquidity = lpm.getPositionLiquidity(tokenId);

        assertEq(liquidity, uint256(params.liquidityDelta));

        uint256 balance0BeforeBurn = getPermissionedCurrency(key.currency0).balanceOfSelf();
        uint256 balance1BeforeBurn = getPermissionedCurrency(key.currency1).balanceOfSelf();
        uint256 balance0ManagerBefore = (key.currency0).balanceOf(address(manager));
        uint256 balance1ManagerBefore = (key.currency1).balanceOf(address(manager));

        // burn liquidity
        decreaseLiquidity(tokenId, config, liquidity, ZERO_BYTES);

        uint256 balance0ManagerAfter = (key.currency0).balanceOf(address(manager));
        uint256 balance1ManagerAfter = (key.currency1).balanceOf(address(manager));

        liquidity = lpm.getPositionLiquidity(tokenId);

        assertEq(liquidity, 0);
        assertEq(
            getPermissionedCurrency(key.currency0).balanceOfSelf(),
            balance0BeforeBurn + balance0ManagerBefore - balance0ManagerAfter
        );
        assertEq(
            getPermissionedCurrency(key.currency1).balanceOfSelf(),
            balance1BeforeBurn + balance1ManagerBefore - balance1ManagerAfter
        );

        IERC721(address(lpm)).ownerOf(lpm.nextTokenId() - 1);

        // see note from position manager test: "no tokens were lost ... fuzzer showing off by 1 sometimes"
        assertApproxEqAbs(key.currency0.balanceOfSelf(), balance0Start, 1 wei);
        assertApproxEqAbs(key.currency1.balanceOfSelf(), balance1Start, 1 wei);
    }

    function test_initialize() public {
        _test_initialize(currency0, currency1);
        _test_initialize(Currency.wrap(address(wrappedToken0)), currency1);
        _test_initialize(currency1, Currency.wrap(address(wrappedToken2)));
        _test_initialize(Currency.wrap(address(wrappedToken0)), Currency.wrap(address(wrappedToken2)));
    }

    function _test_initialize(Currency currency0_, Currency currency1_) internal {
        // initialize a new pool
        PoolKey memory key =
            PoolKey({currency0: currency0_, currency1: currency1_, fee: 0, tickSpacing: 100, hooks: IHooks(address(0))});

        lpm.initializePool(key, SQRT_PRICE_1_1);

        (uint160 sqrtPriceX96, int24 tick, uint24 protocolFee, uint24 lpFee) = manager.getSlot0(key.toId());

        assertEq(sqrtPriceX96, SQRT_PRICE_1_1);
        assertEq(tick, 0);
        assertEq(protocolFee, 0);
        assertEq(lpFee, key.fee);
    }

    function test_fuzz_initialize(uint160 sqrtPrice, uint24 fee) public {
        _test_fuzz_initialize(currency0, currency1, sqrtPrice, fee);
        _test_fuzz_initialize(Currency.wrap(address(wrappedToken0)), currency1, sqrtPrice, fee);
        _test_fuzz_initialize(currency1, Currency.wrap(address(wrappedToken2)), sqrtPrice, fee);
        _test_fuzz_initialize(
            Currency.wrap(address(wrappedToken0)), Currency.wrap(address(wrappedToken2)), sqrtPrice, fee
        );
    }

    function _test_fuzz_initialize(Currency currency0_, Currency currency1_, uint160 sqrtPrice, uint24 fee) internal {
        sqrtPrice =
            uint160(bound(sqrtPrice, TickMath.MIN_SQRT_PRICE, TickMath.MAX_SQRT_PRICE_MINUS_MIN_SQRT_PRICE_MINUS_ONE));
        fee = uint24(bound(fee, 0, LPFeeLibrary.MAX_LP_FEE));
        PoolKey memory key = PoolKey({
            currency0: currency0_,
            currency1: currency1_,
            fee: fee,
            tickSpacing: 10,
            hooks: IHooks(address(0))
        });

        lpm.initializePool(key, sqrtPrice);

        (uint160 sqrtPriceX96, int24 tick, uint24 protocolFee, uint24 lpFee) = manager.getSlot0(key.toId());

        assertEq(sqrtPriceX96, sqrtPrice);
        assertEq(tick, TickMath.getTickAtSqrtPrice(sqrtPrice));
        assertEq(protocolFee, 0);
        assertEq(lpFee, fee);
    }

    function test_liquidity_token_transfer_reverts() public {
        _test_liquidity_token_transfer_reverts(key0);
        _test_liquidity_token_transfer_reverts(key1);
        _test_liquidity_token_transfer_reverts(key2);
    }

    function _test_liquidity_token_transfer_reverts(PoolKey memory key) internal {
        PositionConfig memory config = PositionConfig({poolKey: key, tickLower: -120, tickUpper: 120});

        uint256 liquidity = 1e18;
        uint256 tokenId = lpm.nextTokenId();

        vm.startPrank(alice);

        mint(config, liquidity, ActionConstants.MSG_SENDER, ZERO_BYTES);

        assertEq(IERC721(address(lpm)).ownerOf(tokenId), alice);

        vm.expectRevert();
        IERC721(address(lpm)).transferFrom(alice, address(this), tokenId);
        vm.stopPrank();
    }

    function test_safe_transfer_from_reverts() public {
        bytes memory encodedCall =
            abi.encodeWithSignature("safeTransferFrom(address,address,uint256)", alice, address(this), 1);

        address target = address(lpm);

        vm.startPrank(alice);
        vm.expectRevert(abi.encode("Transfer disabled"));

        bool success;
        assembly ("memory-safe") {
            success := call(gas(), target, 0, add(encodedCall, 0x20), mload(encodedCall), 0, 0)
        }
        vm.stopPrank();
    }

    function test_safe_transfer_from_with_bytes_reverts() public {
        bytes memory encodedCall =
            abi.encodeWithSignature("safeTransferFrom(address,address,uint256,bytes)", alice, address(this), 1, "abcd");
        address target = address(lpm);

        vm.startPrank(alice);
        vm.expectRevert(abi.encode("Transfer disabled"));

        bool success;
        assembly ("memory-safe") {
            success := call(gas(), target, 0, add(encodedCall, 0x20), mload(encodedCall), 0, 0)
        }
        vm.stopPrank();
    }

    function test_mint_from_contract_balance() public {
        _test_mint_from_contract_balance(key0);
        _test_mint_from_contract_balance(key1);
        _test_mint_from_contract_balance(key2);
    }

    /// @dev This function had to be split up and refactored to avoid stack-too-deep errors
    function _test_mint_from_contract_balance(PoolKey memory key) internal {
        uint256 amount0ToTransfer = 100e18;
        uint256 amount1ToTransfer = 100e18;

        // Setup and transfer tokens
        setupContractBalance(key, amount0ToTransfer, amount1ToTransfer);

        // Get balances before minting
        BalanceInfo memory balanceInfo = getBalanceInfo(key);

        // Create and execute mint plan
        bytes memory calls = createMintPlan(key, amount0ToTransfer, amount1ToTransfer);
        uint256 tokenId = lpm.nextTokenId();
        lpm.modifyLiquidities(calls, _deadline);

        // Verify results
        verifyMintResults(key, balanceInfo, tokenId);
    }

    function test_mint_from_contract_balance_disallowed_revert() public {
        _test_mint_from_contract_balance_disallowed_revert(keyFake0);
        _test_mint_from_contract_balance_disallowed_revert(keyFake1);
        _test_mint_from_contract_balance_disallowed_revert(keyFake2);
    }

    function _test_mint_from_contract_balance_disallowed_revert(PoolKey memory key) internal {
        uint256 amount0ToTransfer = 1e18;
        uint256 amount1ToTransfer = 1e18;

        Currency currency0_ = getPermissionedCurrency(key.currency0);
        Currency currency1_ = getPermissionedCurrency(key.currency1);

        uint256 balance0Before = currency0_.balanceOf(address(secondaryPosm));
        uint256 balance1Before = currency1_.balanceOf(address(secondaryPosm));

        // Transfer tokens to the contract
        currency0_.transfer(address(secondaryPosm), amount0ToTransfer);
        currency1_.transfer(address(secondaryPosm), amount1ToTransfer);

        // Calculate liquidity for the desired amounts
        int24 tickLower = -int24(key.tickSpacing);
        int24 tickUpper = int24(key.tickSpacing);
        uint256 liquidityToAdd = LiquidityAmounts.getLiquidityForAmounts(
            SQRT_PRICE_1_1,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            amount0ToTransfer,
            amount1ToTransfer
        );

        PositionConfig memory config = PositionConfig({poolKey: key, tickLower: tickLower, tickUpper: tickUpper});

        // Verify the contract has the tokens
        assertEq(currency0_.balanceOf(address(secondaryPosm)), amount0ToTransfer + balance0Before);
        assertEq(currency1_.balanceOf(address(secondaryPosm)), amount1ToTransfer + balance1Before);

        // Create a plan that uses the contract's balance instead of the caller's
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
                address(this), // recipient
                ZERO_BYTES // hookData
            )
        );

        // Add actions to settle from the contract's balance
        planner.add(Actions.SETTLE, abi.encode(key.currency0, ActionConstants.OPEN_DELTA, false)); // false = payer is contract
        planner.add(Actions.SETTLE, abi.encode(key.currency1, ActionConstants.OPEN_DELTA, false)); // false = payer is contract

        bytes memory calls = planner.finalizeModifyLiquidityWithClose(config.poolKey);

        vm.prank(unauthorizedUser);
        vm.expectRevert();
        secondaryPosm.modifyLiquidities(calls, _deadline);
    }
}
