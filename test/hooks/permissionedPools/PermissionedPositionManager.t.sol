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
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {IPositionManager} from "../../../src/interfaces/IPositionManager.sol";
import {ERC721} from "solmate/src/tokens/ERC721.sol";
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
import {PermissionsAdapter, IERC20} from "../../../src/hooks/permissionedPools/PermissionsAdapter.sol";
import {PermissionFlags, PermissionFlag} from "../../../src/hooks/permissionedPools/libraries/PermissionFlags.sol";
import {INotifier} from "../../../src/interfaces/INotifier.sol";
import {MockUnsubscribeRevertingSubscriber} from "../../mocks/MockUnsubscribeRevertingSubscriber.sol";
import {MockBurnRevertingSubscriber} from "../../mocks/MockBurnRevertingSubscriber.sol";
import {MockReentrantSubscriber} from "../../mocks/MockReentrantSubscriber.sol";
import {MockSubscriber} from "../../mocks/MockSubscriber.sol";

contract PermissionedPositionManagerTest is Test, PermissionedPosmTestSetup, LiquidityFuzzers {
    using FixedPointMathLib for uint256;
    using StateLibrary for IPoolManager;

    // To allow testing without importing PermissionedHooks
    error Unauthorized();
    error InvalidHook();
    error HookCallFailed();

    PoolId public poolId;
    PoolId public poolIdFake;

    // Permissioned components
    MockAllowlistChecker public mockAllowListChecker;
    PermissionsAdapter public permissionsAdapter0;
    PermissionsAdapter public permissionsAdapter2;
    MockERC20 public originalToken0;
    MockERC20 public originalToken2;
    IPositionManager public secondaryPosm;
    IPositionManager public tertiaryPosm;

    // permissioned / normal
    PoolKey public key0;
    // normal / permissioned
    PoolKey public key1;
    // permissioned / permissioned
    PoolKey public key2;
    // normal / normal
    PoolKey public key3;

    PoolKey public keyFake0;
    PoolKey public keyFake1;
    PoolKey public keyFake2;

    PoolKey public insecureKey;

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
        permissionsAdapter0.updateSwappingEnabled(true);
        permissionsAdapter2.updateSwappingEnabled(true);
    }

    function setUpPosms() internal {
        deployAndApprovePosm(manager, address(permissionsAdapterFactory), keccak256("permissionedPosm"));

        // alternate position manager using different hooks
        secondaryPosm =
            deployAndApprovePosmOnly(manager, address(permissionsAdapterFactory), keccak256("secondaryPosm"));

        // alternate position manager using the same hooks
        tertiaryPosm = deployAndApprovePosmOnly(manager, address(permissionsAdapterFactory), keccak256("tertiaryPosm"));
    }

    function setupPool() internal {
        (key0, poolId) =
            initPool(Currency.wrap(address(permissionsAdapter0)), currency1, permissionedHooks, 3000, SQRT_PRICE_1_1);
        (key1, poolId) =
            initPool(currency1, Currency.wrap(address(permissionsAdapter2)), permissionedHooks, 3000, SQRT_PRICE_1_1);
        (key2, poolId) = initPool(
            Currency.wrap(address(permissionsAdapter0)),
            Currency.wrap(address(permissionsAdapter2)),
            permissionedHooks,
            3000,
            SQRT_PRICE_1_1
        );

        (keyFake0, poolId) = initPool(
            Currency.wrap(address(permissionsAdapter0)), currency1, secondaryPermissionedHooks, 3000, SQRT_PRICE_1_1
        );
        (keyFake1, poolId) = initPool(
            currency1, Currency.wrap(address(permissionsAdapter2)), secondaryPermissionedHooks, 3000, SQRT_PRICE_1_1
        );
        (keyFake2, poolId) = initPool(
            Currency.wrap(address(permissionsAdapter0)),
            Currency.wrap(address(permissionsAdapter2)),
            secondaryPermissionedHooks,
            3000,
            SQRT_PRICE_1_1
        );
        (insecureKey, poolId) = initPool(
            Currency.wrap(address(permissionsAdapter0)),
            Currency.wrap(address(permissionsAdapter2)),
            insecureHooks,
            3000,
            SQRT_PRICE_1_1
        );
    }

    function setupPermissionedComponents() internal {
        mockAllowListChecker = new MockAllowlistChecker();
        setUpCurrencyZero();
        setUpCurrencyTwo();
    }

    function setUpCurrencyZero() internal {
        setUpAllowlist(currency0);
        originalToken0 = MockERC20(Currency.unwrap(currency0));
        // ensure expected ordering
        while (true) {
            permissionsAdapter0 = PermissionsAdapter(
                permissionsAdapterFactory.createPermissionsAdapter(
                    IERC20(address(originalToken0)), address(this), mockAllowListChecker
                )
            );
            if (address(permissionsAdapter0) < Currency.unwrap(currency1)) {
                break;
            }
        }
        setUpPermissionsAdapter(permissionsAdapter0, currency0);
    }

    function setUpCurrencyTwo() internal {
        setUpAllowlist(currency2);
        originalToken2 = MockERC20(Currency.unwrap(currency2));

        // ensure expected ordering
        while (true) {
            permissionsAdapter2 = PermissionsAdapter(
                permissionsAdapterFactory.createPermissionsAdapter(
                    IERC20(address(originalToken2)), address(this), mockAllowListChecker
                )
            );
            if (Currency.unwrap(currency1) < address(permissionsAdapter2)) {
                break;
            }
        }
        setUpPermissionsAdapter(permissionsAdapter2, currency2);
    }

    function setUpAllowlist(Currency currency) internal {
        MockPermissionedToken(Currency.unwrap(currency)).setAllowlist(address(this), PermissionFlags.ALL_ALLOWED);
        MockPermissionedToken(Currency.unwrap(currency)).setAllowlist(alice, PermissionFlags.ALL_ALLOWED);
        MockPermissionedToken(Currency.unwrap(currency)).setAllowlist(address(lpm), PermissionFlags.ALL_ALLOWED);
        MockPermissionedToken(Currency.unwrap(currency))
            .setAllowlist(address(secondaryPosm), PermissionFlags.ALL_ALLOWED);
        MockPermissionedToken(Currency.unwrap(currency))
            .setAllowlist(address(permissionsAdapterFactory), PermissionFlags.ALL_ALLOWED);
        MockPermissionedToken(Currency.unwrap(currency)).setAllowlist(address(lpm), PermissionFlags.ALL_ALLOWED);
        MockPermissionedToken(Currency.unwrap(currency)).setAllowlist(address(manager), PermissionFlags.ALL_ALLOWED);
        MockPermissionedToken(Currency.unwrap(currency))
            .setAllowlist(address(permissionedSwapRouter), PermissionFlags.ALL_ALLOWED);
        MockPermissionedToken(Currency.unwrap(currency2))
            .setAllowlist(address(permissionedHooks), PermissionFlags.ALL_ALLOWED);
    }

    function setUpPermissionsAdapter(PermissionsAdapter permissionsAdapter, Currency currency) internal {
        adapterToPermissioned[Currency.wrap(address(permissionsAdapter))] = currency;

        MockPermissionedToken(Currency.unwrap(currency)).mint(address(this), 1000 ether);
        MockPermissionedToken(Currency.unwrap(currency))
            .setAllowlist(address(permissionsAdapter), PermissionFlags.ALL_ALLOWED);

        // permissions adapter contract must have a non-zero balance of the permissioned token
        IERC20(Currency.unwrap(currency)).approve(address(permissionsAdapter), 1);
        permissionsAdapter.depositForVerification(1);

        permissionsAdapter.updateAllowedWrapper(address(manager), true);
        permissionsAdapter.updateAllowedWrapper(address(lpm), true);
        permissionsAdapter.updateAllowedWrapper(address(secondaryPosm), true);
        permissionsAdapter.updateAllowedWrapper(address(permissionedSwapRouter), true);

        permissionsAdapterFactory.verifyPermissionsAdapter(address(permissionsAdapter));

        Currency permissionsAdapterCurrency = Currency.wrap(address(permissionsAdapter));

        setAllowedHooks(lpm, permissionsAdapterCurrency, permissionedHooks);
        setAllowedHooks(tertiaryPosm, permissionsAdapterCurrency, permissionedHooks);

        setAllowedHooks(lpm, permissionsAdapterCurrency, secondaryPermissionedHooks);
        setAllowedHooks(secondaryPosm, permissionsAdapterCurrency, secondaryPermissionedHooks);
        setAllowedHooks(tertiaryPosm, permissionsAdapterCurrency, secondaryPermissionedHooks);

        setAllowedHooks(lpm, permissionsAdapterCurrency, insecureHooks);
    }

    function setAllowedHooks(IPositionManager posm, Currency currency, IHooks permissionedHooks_) internal {
        // setAllowedHook selector
        bytes4 selector = 0xb5cdc484;
        bytes memory data = abi.encodeWithSelector(selector, currency, permissionedHooks_, true);
        (bool success,) = address(posm).call(data);
        require(success, "Failed to set hooks");
    }

    function test_nameAndSymbol() public view {
        ERC721 posm = ERC721(address(lpm));
        assertEq(posm.name(), "Uniswap v4 Permissioned Positions NFT");
        assertEq(posm.symbol(), "UNI-V4-PERM-POSM");
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

        // Create a reentrant token and initialize the pool with a verified adapter so beforeInitialize passes
        Currency reentrantToken = Currency.wrap(address(new ReentrantToken(lpm)));
        Currency adapterCurrency = Currency.wrap(address(permissionsAdapter0));
        (Currency c0, Currency c1) = (Currency.unwrap(reentrantToken) < Currency.unwrap(adapterCurrency))
            ? (reentrantToken, adapterCurrency)
            : (adapterCurrency, reentrantToken);

        // Set up approvals for the reentrant token
        approvePosmCurrency(reentrantToken);
        (key, poolId) = initPool(c0, c1, permissionedHooks, 3000, SQRT_PRICE_1_1);

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
        Currency currency0Adapter = key.currency0;
        Currency currency1Adapter = key.currency1;
        uint256 tokenId = lpm.nextTokenId();
        uint256 balance0Before = currency0_.balanceOfSelf();
        uint256 balance1Before = currency1_.balanceOfSelf();
        uint256 balance0BeforeAlice = currency0_.balanceOf(alice);
        uint256 balance1BeforeAlice = currency1_.balanceOf(alice);
        uint256 balance0ManagerBefore = currency0Adapter.balanceOf(address(manager));
        uint256 balance1ManagerBefore = currency1Adapter.balanceOf(address(manager));

        mint(config, liquidityToAdd, alice, ZERO_BYTES);

        uint256 balance0ManagerAfter = currency0Adapter.balanceOf(address(manager));
        uint256 balance1ManagerAfter = currency1Adapter.balanceOf(address(manager));

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

    function test_permissioned_mint_alt_posm_diff_hooks_reverts() public {
        // secondary posm uses different hooks contract
        _test_permissioned_mint_alt_posm_diff_hooks_reverts(key0, secondaryPosm);
        _test_permissioned_mint_alt_posm_diff_hooks_reverts(key1, secondaryPosm);
        _test_permissioned_mint_alt_posm_diff_hooks_reverts(key2, secondaryPosm);
    }

    function _test_permissioned_mint_alt_posm_diff_hooks_reverts(PoolKey memory key, IPositionManager posm) internal {
        PositionConfig memory config = PositionConfig({poolKey: key, tickLower: -120, tickUpper: 120});

        uint256 liquidity = 1e18;

        // we don't use the helper, so we can choose which position manager to use
        bytes memory calls = getMintEncoded(config, liquidity, ActionConstants.MSG_SENDER, ZERO_BYTES);

        vm.prank(alice);
        vm.expectRevert(InvalidHook.selector);
        posm.modifyLiquidities(calls, block.timestamp + 1);
    }

    function test_permissioned_mint_alt_posm_same_hooks_reverts() public {
        // tertiary posm uses the same hooks contract
        _test_permissioned_mint_alt_posm_same_hooks_reverts(key0, tertiaryPosm);
        _test_permissioned_mint_alt_posm_same_hooks_reverts(key1, tertiaryPosm);
        _test_permissioned_mint_alt_posm_same_hooks_reverts(key2, tertiaryPosm);
    }

    function _test_permissioned_mint_alt_posm_same_hooks_reverts(PoolKey memory key, IPositionManager posm) internal {
        PositionConfig memory config = PositionConfig({poolKey: key, tickLower: -120, tickUpper: 120});

        uint256 liquidity = 1e18;

        // we don't use the helper, so we can choose which position manager to use
        bytes memory calls = getMintEncoded(config, liquidity, ActionConstants.MSG_SENDER, ZERO_BYTES);

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(permissionedHooks),
                IHooks.beforeAddLiquidity.selector,
                abi.encodeWithSelector(Unauthorized.selector),
                abi.encodeWithSelector(HookCallFailed.selector)
            )
        );
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
        MockPermissionedToken(Currency.unwrap(currency0)).setAllowlist(unauthorizedUser, PermissionFlags.ALL_ALLOWED);
        MockPermissionedToken(Currency.unwrap(currency0)).mint(unauthorizedUser, 1000e18);
        MockPermissionedToken(Currency.unwrap(currency0)).setAllowlist(unauthorizedUser, PermissionFlags.NONE);
        MockERC20(Currency.unwrap(currency1)).mint(unauthorizedUser, 1000e18);

        vm.startPrank(unauthorizedUser);

        // Approve tokens for the position manager
        originalToken0.approve(address(permit2), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(permit2), type(uint256).max);
        permit2.approve(address(originalToken0), address(lpm), type(uint160).max, type(uint48).max);
        permit2.approve(Currency.unwrap(currency1), address(lpm), type(uint160).max, type(uint48).max);

        // This should revert because the recipient is not in the allowlist
        vm.expectRevert(Unauthorized.selector);
        mint(config, liquidity, unauthorizedUser, ZERO_BYTES);
        vm.stopPrank();
    }

    /// @dev A pool with no verified permissions adapter on either side has nothing for the
    ///      PermissionedPositionManager to enforce; minting such a position would only produce
    ///      a non-transferable NFT (see ECO-221 / `transferFrom`). Reject the mint outright.
    function test_mint_reverts_when_no_verified_adapter() public {
        // Two ordinary ERC-20s — neither is a verified permissions adapter.
        Currency ordinary0 = deployMintAndApproveCurrency(false);
        Currency ordinary1 = deployMintAndApproveCurrency(false);
        if (Currency.unwrap(ordinary1) < Currency.unwrap(ordinary0)) {
            (ordinary0, ordinary1) = (ordinary1, ordinary0);
        }
        approvePosmCurrency(ordinary0);
        approvePosmCurrency(ordinary1);

        // Initialize directly on the PoolManager with no hooks so initialization isn't gated.
        PoolKey memory ordinaryKey = PoolKey({
            currency0: ordinary0, currency1: ordinary1, fee: 3000, tickSpacing: 60, hooks: IHooks(address(0))
        });
        manager.initialize(ordinaryKey, SQRT_PRICE_1_1);

        PositionConfig memory config = PositionConfig({poolKey: ordinaryKey, tickLower: -120, tickUpper: 120});
        bytes memory calls = getMintEncoded(config, 1e18, ActionConstants.MSG_SENDER, ZERO_BYTES);

        // Use the literal selector to avoid pulling in PermissionedPositionManager imports here.
        // bytes4(keccak256("NoVerifiedAdapter()")) = 0x36a01ad4
        vm.expectRevert(bytes4(keccak256("NoVerifiedAdapter()")));
        lpm.modifyLiquidities(calls, block.timestamp + 1);
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

        MockPermissionedToken(Currency.unwrap(currency0)).setAllowlist(alice, PermissionFlags.NONE);
        MockPermissionedToken(Currency.unwrap(currency2)).setAllowlist(alice, PermissionFlags.NONE);

        tokenId = lpm.nextTokenId();

        // Increasing liquidity should revert because the recipient is no longer in the allowlist
        vm.expectRevert(Unauthorized.selector);
        mint(config, liquidity, ActionConstants.MSG_SENDER, ZERO_BYTES);
        vm.stopPrank();

        MockPermissionedToken(Currency.unwrap(currency0)).setAllowlist(alice, PermissionFlags.ALL_ALLOWED);
        MockPermissionedToken(Currency.unwrap(currency2)).setAllowlist(alice, PermissionFlags.ALL_ALLOWED);
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

        // This should revert because the recipient is not in the allowlist
        vm.expectRevert(Unauthorized.selector);
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
        MockPermissionedToken(Currency.unwrap(currencyPermissioned))
            .setAllowlist(unauthorizedUser, PermissionFlags.ALL_ALLOWED);
        MockPermissionedToken(Currency.unwrap(currencyPermissioned)).mint(unauthorizedUser, 1000e18);
        MockPermissionedToken(Currency.unwrap(currencyPermissioned))
            .setAllowlist(unauthorizedUser, PermissionFlags.NONE);

        vm.startPrank(unauthorizedUser);

        // Approve tokens for the position manager and permit2
        MockERC20(Currency.unwrap(currencyPermissioned)).approve(address(permit2), type(uint256).max);
        permit2.approve(Currency.unwrap(currencyPermissioned), address(lpm), type(uint160).max, type(uint48).max);

        // This should revert because the recipient is not in the allowlist
        vm.expectRevert(Unauthorized.selector);
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
        _test_initialize(Currency.wrap(address(permissionsAdapter0)), currency1);
        _test_initialize(currency1, Currency.wrap(address(permissionsAdapter2)));
        _test_initialize(Currency.wrap(address(permissionsAdapter0)), Currency.wrap(address(permissionsAdapter2)));
    }

    function _test_initialize(Currency currency0_, Currency currency1_) internal {
        // initialize a new pool
        PoolKey memory key = PoolKey({
            currency0: currency0_, currency1: currency1_, fee: 0, tickSpacing: 100, hooks: IHooks(address(0))
        });

        lpm.initializePool(key, SQRT_PRICE_1_1);

        (uint160 sqrtPriceX96, int24 tick, uint24 protocolFee, uint24 lpFee) = manager.getSlot0(key.toId());

        assertEq(sqrtPriceX96, SQRT_PRICE_1_1);
        assertEq(tick, 0);
        assertEq(protocolFee, 0);
        assertEq(lpFee, key.fee);
    }

    function test_fuzz_initialize(uint160 sqrtPrice, uint24 fee) public {
        _test_fuzz_initialize(currency0, currency1, sqrtPrice, fee);
        _test_fuzz_initialize(Currency.wrap(address(permissionsAdapter0)), currency1, sqrtPrice, fee);
        _test_fuzz_initialize(currency1, Currency.wrap(address(permissionsAdapter2)), sqrtPrice, fee);
        _test_fuzz_initialize(
            Currency.wrap(address(permissionsAdapter0)), Currency.wrap(address(permissionsAdapter2)), sqrtPrice, fee
        );
    }

    function _test_fuzz_initialize(Currency currency0_, Currency currency1_, uint160 sqrtPrice, uint24 fee) internal {
        sqrtPrice =
            uint160(bound(sqrtPrice, TickMath.MIN_SQRT_PRICE, TickMath.MAX_SQRT_PRICE_MINUS_MIN_SQRT_PRICE_MINUS_ONE));
        fee = uint24(bound(fee, 0, LPFeeLibrary.MAX_LP_FEE));
        PoolKey memory key = PoolKey({
            currency0: currency0_, currency1: currency1_, fee: fee, tickSpacing: 10, hooks: IHooks(address(0))
        });

        lpm.initializePool(key, sqrtPrice);

        (uint160 sqrtPriceX96, int24 tick, uint24 protocolFee, uint24 lpFee) = manager.getSlot0(key.toId());

        assertEq(sqrtPriceX96, sqrtPrice);
        assertEq(tick, TickMath.getTickAtSqrtPrice(sqrtPrice));
        assertEq(protocolFee, 0);
        assertEq(lpFee, fee);
    }

    error TransferDisabled();

    function test_transferFrom_reverts_transfer_disabled_either_admin() public {
        uint256 tokenId0 = lpm.nextTokenId();
        _test_permissioned_mint_allowed_user(key2);
        uint256 tokenId1 = lpm.nextTokenId();
        _test_permissioned_mint_allowed_user(key2);
        uint256 tokenId2 = lpm.nextTokenId();
        _test_permissioned_mint_allowed_user(key2);

        // address(this) is admin of both permissioned tokens
        vm.expectRevert(TransferDisabled.selector);
        IERC721(address(lpm)).transferFrom(alice, address(this), tokenId0);

        address owner0 = makeAddr("owner0");
        address owner1 = makeAddr("owner1");
        permissionsAdapter0.transferOwnership(owner0);
        vm.prank(owner0);
        permissionsAdapter0.acceptOwnership();
        permissionsAdapter2.transferOwnership(owner1);
        vm.prank(owner1);
        permissionsAdapter2.acceptOwnership();

        vm.startPrank(owner0);
        vm.expectRevert(TransferDisabled.selector);
        IERC721(address(lpm)).transferFrom(alice, address(this), tokenId1);
        vm.stopPrank();

        vm.startPrank(owner1);
        vm.expectRevert(TransferDisabled.selector);
        IERC721(address(lpm)).transferFrom(alice, address(this), tokenId2);
        vm.stopPrank();
    }

    function test_transferFrom_reverts_transfer_disabled(address caller) public {
        _testRevert_transferFrom_reverts_transfer_disabled(key0, caller);
        _testRevert_transferFrom_reverts_transfer_disabled(key1, caller);
        _testRevert_transferFrom_reverts_transfer_disabled(key2, caller);
    }

    function _testRevert_transferFrom_reverts_transfer_disabled(PoolKey memory poolKey, address caller) internal {
        uint256 tokenId = lpm.nextTokenId();
        _test_permissioned_mint_allowed_user(poolKey);

        vm.startPrank(caller);
        vm.expectRevert(TransferDisabled.selector);
        IERC721(address(lpm)).transferFrom(alice, address(this), tokenId);
        vm.stopPrank();
    }

    function test_safe_transfer_from_reverts() public {
        bytes memory encodedCall =
            abi.encodeWithSignature("safeTransferFrom(address,address,uint256)", alice, address(this), 1);

        address target = address(lpm);

        vm.startPrank(alice);
        (bool success, bytes memory data) = address(target).call(encodedCall);

        assertEq(success, false);
        assertEq(bytes4(data), TransferDisabled.selector);
        vm.stopPrank();
    }

    function test_safe_transfer_from_with_bytes_reverts() public {
        bytes memory encodedCall =
            abi.encodeWithSignature("safeTransferFrom(address,address,uint256,bytes)", alice, address(this), 1, "abcd");
        address target = address(lpm);

        vm.startPrank(alice);
        (bool success, bytes memory data) = address(target).call(encodedCall);

        assertEq(success, false);
        assertEq(bytes4(data), TransferDisabled.selector);
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

    function test_mint_from_contract_balance_uses_contract_balance_settle() public {
        _test_mint_from_contract_balance_uses_contract_balance_settle(key0);
        _test_mint_from_contract_balance_uses_contract_balance_settle(key1);
        _test_mint_from_contract_balance_uses_contract_balance_settle(key2);
    }

    function _test_mint_from_contract_balance_uses_contract_balance_settle(PoolKey memory key) internal {
        uint256 amount0ToTransfer = 100e18;
        uint256 amount1ToTransfer = 100e18;

        // Transfer underlying permissioned tokens to the POSM
        setupContractBalance(key, amount0ToTransfer, amount1ToTransfer);

        BalanceInfo memory balanceInfo = getBalanceInfo(key);

        // Create a mint plan that uses CONTRACT_BALANCE instead of OPEN_DELTA
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

        // Use CONTRACT_BALANCE instead of OPEN_DELTA — this is the broken path
        planner.add(Actions.SETTLE, abi.encode(key.currency0, ActionConstants.CONTRACT_BALANCE, false));
        planner.add(Actions.SETTLE, abi.encode(key.currency1, ActionConstants.CONTRACT_BALANCE, false));

        bytes memory calls = planner.finalizeModifyLiquidityWithClose(config.poolKey);
        uint256 tokenId = lpm.nextTokenId();
        lpm.modifyLiquidities(calls, _deadline);

        verifyMintResults(key, balanceInfo, tokenId);
    }

    // ===== PERMISSION FLAG TESTS =====

    function test_permission_flag_none() public {
        // Test that NONE permissions prevent all operations
        MockPermissionedToken(Currency.unwrap(currency0)).setAllowlist(alice, PermissionFlags.NONE);
        MockPermissionedToken(Currency.unwrap(currency2)).setAllowlist(alice, PermissionFlags.NONE);

        // Should revert when trying to mint with NONE permissions
        PositionConfig memory config = PositionConfig({poolKey: key2, tickLower: -120, tickUpper: 120});
        uint256 liquidity = 1e18;

        vm.prank(alice);
        vm.expectRevert();
        mint(config, liquidity, ActionConstants.MSG_SENDER, ZERO_BYTES);
    }

    function test_permission_flag_swap_allowed() public {
        // Test that SWAP_ALLOWED only allows swaps, not liquidity operations
        MockPermissionedToken(Currency.unwrap(currency0)).setAllowlist(alice, PermissionFlags.SWAP_ALLOWED);
        MockPermissionedToken(Currency.unwrap(currency2)).setAllowlist(alice, PermissionFlags.SWAP_ALLOWED);

        // Should revert when trying to mint (liquidity operation) with only SWAP_ALLOWED
        PositionConfig memory config = PositionConfig({poolKey: key2, tickLower: -120, tickUpper: 120});
        uint256 liquidity = 1e18;

        vm.prank(alice);
        vm.expectRevert();
        mint(config, liquidity, ActionConstants.MSG_SENDER, ZERO_BYTES);
    }

    function test_permission_flag_liquidity_allowed() public {
        // Test that LIQUIDITY_ALLOWED allows liquidity operations
        MockPermissionedToken(Currency.unwrap(currency0)).setAllowlist(alice, PermissionFlags.LIQUIDITY_ALLOWED);
        MockPermissionedToken(Currency.unwrap(currency2)).setAllowlist(alice, PermissionFlags.LIQUIDITY_ALLOWED);

        // Should succeed when trying to mint with LIQUIDITY_ALLOWED
        PositionConfig memory config = PositionConfig({poolKey: key2, tickLower: -120, tickUpper: 120});
        uint256 liquidity = 1e18;
        uint256 tokenId = lpm.nextTokenId();

        vm.prank(alice);
        mint(config, liquidity, ActionConstants.MSG_SENDER, ZERO_BYTES);

        assertEq(IERC721(address(lpm)).ownerOf(tokenId), alice);
    }

    function test_permission_flag_all_allowed() public {
        // Test that ALL_ALLOWED allows all operations
        MockPermissionedToken(Currency.unwrap(currency0)).setAllowlist(alice, PermissionFlags.ALL_ALLOWED);
        MockPermissionedToken(Currency.unwrap(currency2)).setAllowlist(alice, PermissionFlags.ALL_ALLOWED);

        // Should succeed when trying to mint with ALL_ALLOWED
        PositionConfig memory config = PositionConfig({poolKey: key2, tickLower: -120, tickUpper: 120});
        uint256 liquidity = 1e18;
        uint256 tokenId = lpm.nextTokenId();

        vm.prank(alice);
        mint(config, liquidity, ActionConstants.MSG_SENDER, ZERO_BYTES);

        assertEq(IERC721(address(lpm)).ownerOf(tokenId), alice);
    }

    function test_permission_flag_combinations() public {
        // Test various combinations of permissions
        PositionConfig memory config = PositionConfig({poolKey: key2, tickLower: -120, tickUpper: 120});
        uint256 liquidity = 1e18;

        // Test SWAP_ALLOWED + LIQUIDITY_ALLOWED (should work like ALL_ALLOWED)
        MockPermissionedToken(Currency.unwrap(currency0))
            .setAllowlist(alice, (PermissionFlags.SWAP_ALLOWED | PermissionFlags.LIQUIDITY_ALLOWED));
        MockPermissionedToken(Currency.unwrap(currency2))
            .setAllowlist(alice, (PermissionFlags.SWAP_ALLOWED | PermissionFlags.LIQUIDITY_ALLOWED));

        uint256 tokenId = lpm.nextTokenId();
        vm.prank(alice);
        mint(config, liquidity, ActionConstants.MSG_SENDER, ZERO_BYTES);
        assertEq(IERC721(address(lpm)).ownerOf(tokenId), alice);
    }

    function test_permission_flag_partial_permissions_reverts() public {
        // Test that having permissions on only one of the pool's tokens is not enough
        MockPermissionedToken(Currency.unwrap(currency0)).setAllowlist(alice, PermissionFlags.LIQUIDITY_ALLOWED);
        MockPermissionedToken(Currency.unwrap(currency2)).setAllowlist(alice, PermissionFlags.NONE);

        PositionConfig memory config = PositionConfig({poolKey: key2, tickLower: -120, tickUpper: 120});
        uint256 liquidity = 1e18;

        vm.prank(alice);
        vm.expectRevert();
        mint(config, liquidity, ActionConstants.MSG_SENDER, ZERO_BYTES);
    }

    function test_permission_flag_dynamic_changes() public {
        // Test that permission changes take effect immediately
        MockPermissionedToken(Currency.unwrap(currency0)).setAllowlist(alice, PermissionFlags.LIQUIDITY_ALLOWED);
        MockPermissionedToken(Currency.unwrap(currency2)).setAllowlist(alice, PermissionFlags.LIQUIDITY_ALLOWED);

        PositionConfig memory config = PositionConfig({poolKey: key2, tickLower: -120, tickUpper: 120});
        uint256 liquidity = 1e18;

        // Should succeed initially
        uint256 tokenId = lpm.nextTokenId();
        vm.prank(alice);
        mint(config, liquidity, ActionConstants.MSG_SENDER, ZERO_BYTES);
        assertEq(IERC721(address(lpm)).ownerOf(tokenId), alice);

        // Remove permissions
        MockPermissionedToken(Currency.unwrap(currency0)).setAllowlist(alice, PermissionFlags.NONE);
        MockPermissionedToken(Currency.unwrap(currency2)).setAllowlist(alice, PermissionFlags.NONE);

        // Should fail on subsequent operations
        tokenId = lpm.nextTokenId();
        vm.prank(alice);
        vm.expectRevert();
        mint(config, liquidity, ActionConstants.MSG_SENDER, ZERO_BYTES);
    }

    function test_permission_flag_edge_cases() public {
        // Test edge cases with permission flags
        PositionConfig memory config = PositionConfig({poolKey: key2, tickLower: -120, tickUpper: 120});
        uint256 liquidity = 1e18;

        // Test with zero permissions (should be same as NONE)
        MockPermissionedToken(Currency.unwrap(currency0)).setAllowlist(alice, PermissionFlag.wrap(0x0000));
        MockPermissionedToken(Currency.unwrap(currency2)).setAllowlist(alice, PermissionFlag.wrap(0x0000));

        vm.prank(alice);
        vm.expectRevert();
        mint(config, liquidity, ActionConstants.MSG_SENDER, ZERO_BYTES);

        // Test with maximum permissions (should be same as ALL_ALLOWED)
        MockPermissionedToken(Currency.unwrap(currency0)).setAllowlist(alice, PermissionFlag.wrap(0xFFFF));
        MockPermissionedToken(Currency.unwrap(currency2)).setAllowlist(alice, PermissionFlag.wrap(0xFFFF));

        uint256 tokenId = lpm.nextTokenId();
        vm.prank(alice);
        mint(config, liquidity, ActionConstants.MSG_SENDER, ZERO_BYTES);
        assertEq(IERC721(address(lpm)).ownerOf(tokenId), alice);
    }

    function test_permission_flag_all_pools() public {
        // Test permission flags work across all pool types
        MockPermissionedToken(Currency.unwrap(currency0)).setAllowlist(alice, PermissionFlags.LIQUIDITY_ALLOWED);
        MockPermissionedToken(Currency.unwrap(currency2)).setAllowlist(alice, PermissionFlags.LIQUIDITY_ALLOWED);

        PositionConfig memory config0 = PositionConfig({poolKey: key0, tickLower: -120, tickUpper: 120});
        PositionConfig memory config1 = PositionConfig({poolKey: key1, tickLower: -120, tickUpper: 120});
        PositionConfig memory config2 = PositionConfig({poolKey: key2, tickLower: -120, tickUpper: 120});
        uint256 liquidity = 1e18;

        // Test permissioned/normal pool
        uint256 tokenId0 = lpm.nextTokenId();
        vm.prank(alice);
        mint(config0, liquidity, ActionConstants.MSG_SENDER, ZERO_BYTES);
        assertEq(IERC721(address(lpm)).ownerOf(tokenId0), alice);

        // Test normal/permissioned pool
        uint256 tokenId1 = lpm.nextTokenId();
        vm.prank(alice);
        mint(config1, liquidity, ActionConstants.MSG_SENDER, ZERO_BYTES);
        assertEq(IERC721(address(lpm)).ownerOf(tokenId1), alice);

        // Test permissioned/permissioned pool
        uint256 tokenId2 = lpm.nextTokenId();
        vm.prank(alice);
        mint(config2, liquidity, ActionConstants.MSG_SENDER, ZERO_BYTES);
        assertEq(IERC721(address(lpm)).ownerOf(tokenId2), alice);
    }

    function test_permission_flag_swap_allowed_unauthorized_reverts() public {
        // Test that SWAP_ALLOWED does not allow liquidity operations
        MockPermissionedToken(Currency.unwrap(currency0)).setAllowlist(alice, PermissionFlags.SWAP_ALLOWED);
        MockPermissionedToken(Currency.unwrap(currency2)).setAllowlist(alice, PermissionFlags.SWAP_ALLOWED);

        // Should revert when trying to mint with SWAP_ALLOWED
        PositionConfig memory config = PositionConfig({poolKey: insecureKey, tickLower: -120, tickUpper: 120});
        uint256 liquidity = 1e18;

        vm.startPrank(alice);
        vm.expectRevert(Unauthorized.selector);
        mint(config, liquidity, ActionConstants.MSG_SENDER, ZERO_BYTES);
        vm.stopPrank();
    }

    function test_permissioned_mint_to_unauthorized_recipient_reverts() public {
        // Caller (address(this)) is allowed, but unauthorizedUser is not
        // The hook will pass because the caller is authorized,
        // but _mint should revert because the recipient lacks LIQUIDITY_ALLOWED
        PositionConfig memory config = PositionConfig({poolKey: key0, tickLower: -120, tickUpper: 120});
        uint256 liquidity = 1e18;

        vm.expectRevert(Unauthorized.selector);
        mint(config, liquidity, unauthorizedUser, ZERO_BYTES);
    }

    function test_permissioned_mint_to_authorized_recipient_succeeds() public {
        // Caller (address(this)) is allowed, alice is also allowed
        // Minting to an authorized recipient should succeed
        PositionConfig memory config = PositionConfig({poolKey: key0, tickLower: -120, tickUpper: 120});
        uint256 liquidity = 1e18;
        uint256 tokenId = lpm.nextTokenId();

        mint(config, liquidity, alice, ZERO_BYTES);
        assertEq(IERC721(address(lpm)).ownerOf(tokenId), alice);
    }

    // =============================================================================
    // Hook allowlist revocation enforcement on liquidity increases (ECO-218 / SC-L-07)
    // =============================================================================

    function test_permissioned_increase_disallowed_hook_reverts() public {
        _test_permissioned_increase_disallowed_hook_reverts(key0);
        _test_permissioned_increase_disallowed_hook_reverts(key1);
        _test_permissioned_increase_disallowed_hook_reverts(key2);
    }

    function _test_permissioned_increase_disallowed_hook_reverts(PoolKey memory key) internal {
        PositionConfig memory config = PositionConfig({poolKey: key, tickLower: -120, tickUpper: 120});
        uint256 liquidity = 1e18;
        uint256 tokenId = lpm.nextTokenId();

        vm.prank(alice);
        mint(config, liquidity, ActionConstants.MSG_SENDER, ZERO_BYTES);

        uint128 liquidityBefore = lpm.getPositionLiquidity(tokenId);

        // Revoke the hook as the adapter admin (address(this) owns both permissionsAdapter0 and permissionsAdapter2)
        _setHookAllowedForKey(key, false);

        vm.prank(alice);
        vm.expectRevert(InvalidHook.selector);
        increaseLiquidity(tokenId, config, liquidity, ZERO_BYTES);

        assertEq(lpm.getPositionLiquidity(tokenId), liquidityBefore);

        // restore so the fan-out across keys is independent
        _setHookAllowedForKey(key, true);
    }

    function test_permissioned_increaseFromDeltas_disallowed_hook_reverts() public {
        _test_permissioned_increaseFromDeltas_disallowed_hook_reverts(key0);
        _test_permissioned_increaseFromDeltas_disallowed_hook_reverts(key1);
        _test_permissioned_increaseFromDeltas_disallowed_hook_reverts(key2);
    }

    function _test_permissioned_increaseFromDeltas_disallowed_hook_reverts(PoolKey memory key) internal {
        PositionConfig memory config = PositionConfig({poolKey: key, tickLower: -120, tickUpper: 120});
        uint256 initialLiquidity = 1e18;
        uint256 tokenId = lpm.nextTokenId();

        vm.prank(alice);
        mint(config, initialLiquidity, ActionConstants.MSG_SENDER, ZERO_BYTES);

        uint128 liquidityBefore = lpm.getPositionLiquidity(tokenId);

        _setHookAllowedForKey(key, false);

        // Build a plan that pre-settles both currencies then drives INCREASE_LIQUIDITY_FROM_DELTAS.
        // The hook-allowlist check runs at the top of the override, so the whole batch reverts
        // atomically and no funds move.
        Plan memory planner = Planner.init();
        planner.add(Actions.SETTLE, abi.encode(key.currency0, uint256(10e18), true));
        planner.add(Actions.SETTLE, abi.encode(key.currency1, uint256(10e18), true));
        planner.add(
            Actions.INCREASE_LIQUIDITY_FROM_DELTAS,
            abi.encode(tokenId, MAX_SLIPPAGE_INCREASE, MAX_SLIPPAGE_INCREASE, ZERO_BYTES)
        );
        bytes memory calls = planner.encode();

        vm.prank(alice);
        vm.expectRevert(InvalidHook.selector);
        lpm.modifyLiquidities(calls, _deadline);

        assertEq(lpm.getPositionLiquidity(tokenId), liquidityBefore);

        _setHookAllowedForKey(key, true);
    }

    function test_permissioned_increase_succeeds_when_hook_still_allowed() public {
        _test_permissioned_increase_succeeds_when_hook_still_allowed(key0);
        _test_permissioned_increase_succeeds_when_hook_still_allowed(key1);
        _test_permissioned_increase_succeeds_when_hook_still_allowed(key2);
    }

    function _test_permissioned_increase_succeeds_when_hook_still_allowed(PoolKey memory key) internal {
        PositionConfig memory config = PositionConfig({poolKey: key, tickLower: -120, tickUpper: 120});
        uint256 liquidity = 1e18;
        uint256 tokenId = lpm.nextTokenId();

        vm.prank(alice);
        mint(config, liquidity, ActionConstants.MSG_SENDER, ZERO_BYTES);

        uint128 liquidityBefore = lpm.getPositionLiquidity(tokenId);

        vm.prank(alice);
        increaseLiquidity(tokenId, config, liquidity, ZERO_BYTES);

        assertEq(lpm.getPositionLiquidity(tokenId), liquidityBefore + uint128(liquidity));
    }

    function test_permissioned_increase_succeeds_then_reverts_after_revocation() public {
        _test_permissioned_increase_succeeds_then_reverts_after_revocation(key0);
        _test_permissioned_increase_succeeds_then_reverts_after_revocation(key1);
        _test_permissioned_increase_succeeds_then_reverts_after_revocation(key2);
    }

    function _test_permissioned_increase_succeeds_then_reverts_after_revocation(PoolKey memory key) internal {
        PositionConfig memory config = PositionConfig({poolKey: key, tickLower: -120, tickUpper: 120});
        uint256 liquidity = 1e18;
        uint256 tokenId = lpm.nextTokenId();

        vm.prank(alice);
        mint(config, liquidity, ActionConstants.MSG_SENDER, ZERO_BYTES);

        // While the hook is still allowed, increase succeeds.
        vm.prank(alice);
        increaseLiquidity(tokenId, config, liquidity, ZERO_BYTES);
        uint128 liquidityAfterFirstIncrease = lpm.getPositionLiquidity(tokenId);

        // Revoke the hook — the next increase must revert.
        _setHookAllowedForKey(key, false);

        vm.prank(alice);
        vm.expectRevert(InvalidHook.selector);
        increaseLiquidity(tokenId, config, liquidity, ZERO_BYTES);

        assertEq(lpm.getPositionLiquidity(tokenId), liquidityAfterFirstIncrease);

        _setHookAllowedForKey(key, true);
    }

    function test_permissioned_increase_reverts_when_only_one_currency_hook_revoked() public {
        // Use key2 (permissioned/permissioned) to exercise the `&&` short-circuit in _checkAllowedHooks.
        // Each side's mapping entry must independently block an increase.
        _test_permissioned_increase_reverts_when_only_one_currency_hook_revoked(key2, true);
        _test_permissioned_increase_reverts_when_only_one_currency_hook_revoked(key2, false);
    }

    function _test_permissioned_increase_reverts_when_only_one_currency_hook_revoked(
        PoolKey memory key,
        bool revokeCurrency0
    ) internal {
        PositionConfig memory config = PositionConfig({poolKey: key, tickLower: -120, tickUpper: 120});
        uint256 liquidity = 1e18;
        uint256 tokenId = lpm.nextTokenId();

        vm.prank(alice);
        mint(config, liquidity, ActionConstants.MSG_SENDER, ZERO_BYTES);

        Currency revoked = revokeCurrency0 ? key.currency0 : key.currency1;
        _setHookAllowed(revoked, key.hooks, false);

        vm.prank(alice);
        vm.expectRevert(InvalidHook.selector);
        increaseLiquidity(tokenId, config, liquidity, ZERO_BYTES);

        // Restore for the next iteration so the tests are independent.
        _setHookAllowed(revoked, key.hooks, true);
    }

    // =============================================================================
    // Owner LIQUIDITY_ALLOWED enforcement on liquidity increases (ECO-347 / Cantina #17)
    // =============================================================================
    //
    // An ERC-721-approved operator that retains LIQUIDITY_ALLOWED must not be able to grow
    // a delisted owner's position by paying with their own funds. `_increase` and
    // `_increaseFromDeltas` re-check `_checkRecipientAllowed(currency, ownerOf(tokenId))`.

    function test_permissioned_increase_reverts_when_owner_liquidity_revoked_via_operator() public {
        _test_permissioned_increase_reverts_when_owner_liquidity_revoked_via_operator(key0);
        _test_permissioned_increase_reverts_when_owner_liquidity_revoked_via_operator(key1);
        _test_permissioned_increase_reverts_when_owner_liquidity_revoked_via_operator(key2);
    }

    function _test_permissioned_increase_reverts_when_owner_liquidity_revoked_via_operator(PoolKey memory key)
        internal
    {
        address bob = makeAddr("BOB");
        // Bob holds LIQUIDITY_ALLOWED on every permissioned underlying and is funded so he can
        // pay for the increase from his own balance.
        MockPermissionedToken(Currency.unwrap(currency0)).setAllowlist(bob, PermissionFlags.ALL_ALLOWED);
        MockPermissionedToken(Currency.unwrap(currency2)).setAllowlist(bob, PermissionFlags.ALL_ALLOWED);
        seedBalance(bob);
        approvePosmFor(bob);

        PositionConfig memory config = PositionConfig({poolKey: key, tickLower: -120, tickUpper: 120});
        uint256 liquidity = 1e18;
        uint256 tokenId = lpm.nextTokenId();

        // Alice mints a position while she still has LIQUIDITY_ALLOWED.
        vm.prank(alice);
        mint(config, liquidity, ActionConstants.MSG_SENDER, ZERO_BYTES);
        uint128 liquidityBefore = lpm.getPositionLiquidity(tokenId);

        // Alice approves Bob via ERC-721 so he can operate on her tokenId.
        vm.prank(alice);
        IERC721(address(lpm)).approve(bob, tokenId);

        // Alice's adapter revokes her permissions on every permissioned underlying.
        MockPermissionedToken(Currency.unwrap(currency0)).setAllowlist(alice, PermissionFlags.NONE);
        MockPermissionedToken(Currency.unwrap(currency2)).setAllowlist(alice, PermissionFlags.NONE);

        // Bob — still allowlisted, still ERC-721-approved — must not be able to grow Alice's
        // position by paying with his own funds.
        vm.prank(bob);
        vm.expectRevert(Unauthorized.selector);
        increaseLiquidity(tokenId, config, liquidity, ZERO_BYTES);

        // Position size unchanged.
        assertEq(lpm.getPositionLiquidity(tokenId), liquidityBefore);

        // Restore so the fan-out across keys is independent.
        MockPermissionedToken(Currency.unwrap(currency0)).setAllowlist(alice, PermissionFlags.ALL_ALLOWED);
        MockPermissionedToken(Currency.unwrap(currency2)).setAllowlist(alice, PermissionFlags.ALL_ALLOWED);
    }

    function test_permissioned_increaseFromDeltas_reverts_when_owner_liquidity_revoked_via_operator() public {
        _test_permissioned_increaseFromDeltas_reverts_when_owner_liquidity_revoked_via_operator(key0);
        _test_permissioned_increaseFromDeltas_reverts_when_owner_liquidity_revoked_via_operator(key1);
        _test_permissioned_increaseFromDeltas_reverts_when_owner_liquidity_revoked_via_operator(key2);
    }

    function _test_permissioned_increaseFromDeltas_reverts_when_owner_liquidity_revoked_via_operator(PoolKey memory key)
        internal
    {
        address bob = makeAddr("BOB_DELTAS");
        MockPermissionedToken(Currency.unwrap(currency0)).setAllowlist(bob, PermissionFlags.ALL_ALLOWED);
        MockPermissionedToken(Currency.unwrap(currency2)).setAllowlist(bob, PermissionFlags.ALL_ALLOWED);
        seedBalance(bob);
        approvePosmFor(bob);

        PositionConfig memory config = PositionConfig({poolKey: key, tickLower: -120, tickUpper: 120});
        uint256 initialLiquidity = 1e18;
        uint256 tokenId = lpm.nextTokenId();

        vm.prank(alice);
        mint(config, initialLiquidity, ActionConstants.MSG_SENDER, ZERO_BYTES);
        uint128 liquidityBefore = lpm.getPositionLiquidity(tokenId);

        vm.prank(alice);
        IERC721(address(lpm)).approve(bob, tokenId);

        MockPermissionedToken(Currency.unwrap(currency0)).setAllowlist(alice, PermissionFlags.NONE);
        MockPermissionedToken(Currency.unwrap(currency2)).setAllowlist(alice, PermissionFlags.NONE);

        // Build a plan that pre-settles both currencies then drives INCREASE_LIQUIDITY_FROM_DELTAS.
        // The owner-allowlist check runs at the top of the override, so the whole batch reverts
        // atomically and no funds move.
        Plan memory planner = Planner.init();
        planner.add(Actions.SETTLE, abi.encode(key.currency0, uint256(10e18), true));
        planner.add(Actions.SETTLE, abi.encode(key.currency1, uint256(10e18), true));
        planner.add(
            Actions.INCREASE_LIQUIDITY_FROM_DELTAS,
            abi.encode(tokenId, MAX_SLIPPAGE_INCREASE, MAX_SLIPPAGE_INCREASE, ZERO_BYTES)
        );
        bytes memory calls = planner.encode();

        vm.prank(bob);
        vm.expectRevert(Unauthorized.selector);
        lpm.modifyLiquidities(calls, _deadline);

        assertEq(lpm.getPositionLiquidity(tokenId), liquidityBefore);

        MockPermissionedToken(Currency.unwrap(currency0)).setAllowlist(alice, PermissionFlags.ALL_ALLOWED);
        MockPermissionedToken(Currency.unwrap(currency2)).setAllowlist(alice, PermissionFlags.ALL_ALLOWED);
    }

    // Helpers for toggling the hook allowlist in tests. Uses a raw selector call to mirror the
    // pattern established by `setAllowedHooks` (line 227).
    function _setHookAllowedForKey(PoolKey memory key, bool allowed) internal {
        _setHookAllowedIfPermissioned(key.currency0, key.hooks, allowed);
        _setHookAllowedIfPermissioned(key.currency1, key.hooks, allowed);
    }

    function _setHookAllowedIfPermissioned(Currency currency, IHooks hooks_, bool allowed) internal {
        // setAllowedHook requires the currency to have a verified permissions adapter;
        // skip unpermissioned currencies so mixed-pool keys (key0, key1) work with this helper.
        if (permissionsAdapterFactory.verifiedPermissionsAdapterOf(Currency.unwrap(currency)) == address(0)) return;
        _setHookAllowed(currency, hooks_, allowed);
    }

    function _setHookAllowed(Currency currency, IHooks hooks_, bool allowed) internal {
        // setAllowedHook(Currency,IHooks,bool) selector
        bytes4 selector = 0xb5cdc484;
        (bool success,) = address(lpm).call(abi.encodeWithSelector(selector, currency, hooks_, allowed));
        require(success, "setAllowedHook failed");
    }

    // ===== unwindPosition / withdrawClaim helpers =====

    /// @dev V4 rounds in favor of the pool: a mint+burn roundtrip loses up to 1 wei per side.
    uint256 private constant _ROUNDTRIP_TOLERANCE = 1;
    bytes4 private constant _UNWIND_SELECTOR = 0x37058749;
    bytes4 private constant _WITHDRAW_CLAIM_SELECTOR = 0xf77de3fc;

    event CurrencyUnwound(
        uint256 indexed tokenId,
        Currency indexed currency,
        address indexed recipient,
        address caller,
        address lp,
        uint256 amount,
        bool asClaim
    );
    event ClaimWithdrawn(Currency indexed currency, address indexed from, address indexed to, uint256 amount);

    function _balanceOf(Currency c, address who) internal view returns (uint256) {
        return IERC20(Currency.unwrap(c)).balanceOf(who);
    }

    function _unwind(uint256 tokenId) internal {
        (bool ok,) = address(lpm).call(abi.encodeWithSelector(_UNWIND_SELECTOR, tokenId));
        require(ok, "unwindPosition failed");
    }

    function _withdrawClaim(Currency currency, uint256 amount, address to) internal {
        (bool ok,) = address(lpm).call(abi.encodeWithSelector(_WITHDRAW_CLAIM_SELECTOR, currency, amount, to));
        require(ok, "withdrawClaim failed");
    }

    /// @dev Hands pa0 ownership to `admin1`, pa2 ownership to `admin2`, and filters fuzz inputs to keep the
    ///      cascade premise sane. Pass `admin1 == admin2` for the same-admin case.
    function _setupUnwindPositionTests(address admin1, address admin2) internal {
        // admins must be valid Ownable2Step recipients and distinct from protocol contracts
        vm.assume(admin1 != address(0) && admin2 != address(0));
        vm.assume(admin1 != alice && admin2 != alice);
        vm.assume(admin1 != address(manager) && admin2 != address(manager));
        vm.assume(admin1 != address(lpm) && admin2 != address(lpm));

        permissionsAdapter0.transferOwnership(admin1);
        vm.prank(admin1);
        permissionsAdapter0.acceptOwnership();

        permissionsAdapter2.transferOwnership(admin2);
        vm.prank(admin2);
        permissionsAdapter2.acceptOwnership();
    }

    // ===== Case 1: both currencies are PAs owned by the same admin (admin1 == admin2) =====

    /// @dev Case 1: same admin owns both PAs, LP compliant on both → both legs cascade to LP.
    function test_unwindPosition_two_pas_same_admin_routes_both_to_lp(address admin) public {
        _setupUnwindPositionTests(admin, admin);

        uint256 aliceCurrency0BeforeMint = _balanceOf(currency0, alice);
        uint256 aliceCurrency2BeforeMint = _balanceOf(currency2, alice);

        uint256 tokenId = lpm.nextTokenId();
        _test_permissioned_mint_allowed_user(key2);

        // capture the exact deposit amounts so we can do a full-data event check
        uint256 deposited0 = aliceCurrency0BeforeMint - _balanceOf(currency0, alice);
        uint256 deposited2 = aliceCurrency2BeforeMint - _balanceOf(currency2, alice);

        // Full-data check verifies caller == admin (msgSender() returns the unwindPosition caller, not PoolManager).
        vm.expectEmit(true, true, true, true);
        emit CurrencyUnwound(tokenId, key2.currency0, alice, admin, alice, deposited0 - 1, false);
        vm.expectEmit(true, true, true, true);
        emit CurrencyUnwound(tokenId, key2.currency1, alice, admin, alice, deposited2 - 1, false);
        vm.prank(admin);
        _unwind(tokenId);

        // alice should be roughly whole on both currencies
        assertApproxEqAbs(_balanceOf(currency0, alice), aliceCurrency0BeforeMint, _ROUNDTRIP_TOLERANCE);
        assertApproxEqAbs(_balanceOf(currency2, alice), aliceCurrency2BeforeMint, _ROUNDTRIP_TOLERANCE);
    }

    // ===== Case 2: one PA + one regular ERC-20; admin1 (= owner of pa0) calls =====

    /// @dev Case 2a: LP compliant on pa0's underlying → both cascade to LP.
    function test_unwindPosition_pa_and_regular_routes_both_to_lp_when_compliant(address admin1, address admin2)
        public
    {
        _setupUnwindPositionTests(admin1, admin2);

        uint256 aliceCurrency0BeforeMint = _balanceOf(currency0, alice);
        uint256 aliceCurrency1BeforeMint = _balanceOf(key0.currency1, alice);

        uint256 tokenId = lpm.nextTokenId();
        _test_permissioned_mint_allowed_user(key0);

        vm.prank(admin1);
        _unwind(tokenId);

        assertApproxEqAbs(_balanceOf(currency0, alice), aliceCurrency0BeforeMint, _ROUNDTRIP_TOLERANCE);
        assertApproxEqAbs(_balanceOf(key0.currency1, alice), aliceCurrency1BeforeMint, _ROUNDTRIP_TOLERANCE);
    }

    /// @dev Case 2b: LP delisted on pa0's underlying → pa0 cascades to admin1; regular still goes to LP.
    function test_unwindPosition_pa_and_regular_routes_pa_to_admin_when_lp_blocked(address admin1, address admin2)
        public
    {
        _setupUnwindPositionTests(admin1, admin2);

        uint256 aliceCurrency0BeforeMint = _balanceOf(currency0, alice);
        uint256 aliceCurrency1BeforeMint = _balanceOf(key0.currency1, alice);
        uint256 adminCurrency0BeforeMint = _balanceOf(currency0, admin1);

        uint256 tokenId = lpm.nextTokenId();
        _test_permissioned_mint_allowed_user(key0);

        // capture how much pa0 underlying alice deposited at mint time
        uint256 deposited0 = aliceCurrency0BeforeMint - _balanceOf(currency0, alice);

        MockPermissionedToken(Currency.unwrap(currency0)).setTokenAllowlist(alice, false);
        MockPermissionedToken(Currency.unwrap(currency0)).setTokenAllowlist(admin1, true);

        // pa0 leg lands at admin1 as underlying; regular leg lands at alice as underlying
        vm.expectEmit(true, true, true, false);
        emit CurrencyUnwound(tokenId, key0.currency0, admin1, address(0), address(0), 0, false);
        vm.expectEmit(true, true, true, false);
        emit CurrencyUnwound(tokenId, key0.currency1, alice, address(0), address(0), 0, false);
        vm.prank(admin1);
        _unwind(tokenId);

        // admin1 receives ~exactly what alice deposited on pa0; regular currency goes back to alice
        assertApproxEqAbs(_balanceOf(currency0, admin1) - adminCurrency0BeforeMint, deposited0, _ROUNDTRIP_TOLERANCE);
        assertApproxEqAbs(_balanceOf(key0.currency1, alice), aliceCurrency1BeforeMint, _ROUNDTRIP_TOLERANCE);
    }

    /// @dev Case 2c: neither LP nor admin1 on pa0's underlying → pa0 lands as 6909 claim to admin1.
    function test_unwindPosition_pa_and_regular_credits_6909_when_lp_and_admin_blocked(address admin1, address admin2)
        public
    {
        _setupUnwindPositionTests(admin1, admin2);

        uint256 aliceCurrency0BeforeMint = _balanceOf(currency0, alice);
        uint256 aliceCurrency1BeforeMint = _balanceOf(key0.currency1, alice);

        uint256 tokenId = lpm.nextTokenId();
        _test_permissioned_mint_allowed_user(key0);

        uint256 deposited0 = aliceCurrency0BeforeMint - _balanceOf(currency0, alice);

        MockPermissionedToken(Currency.unwrap(currency0)).setTokenAllowlist(alice, false);
        MockPermissionedToken(Currency.unwrap(currency0)).setTokenAllowlist(admin1, false);

        // pa0 leg lands at admin1 as 6909 (asClaim=true); regular leg lands at alice as underlying
        vm.expectEmit(true, true, true, false);
        emit CurrencyUnwound(tokenId, key0.currency0, admin1, address(0), address(0), 0, true);
        vm.expectEmit(true, true, true, false);
        emit CurrencyUnwound(tokenId, key0.currency1, alice, address(0), address(0), 0, false);
        vm.prank(admin1);
        _unwind(tokenId);

        // 6909 claim to admin1 ≈ alice's pa0 deposit; regular currency goes back to alice
        assertApproxEqAbs(manager.balanceOf(admin1, key0.currency0.toId()), deposited0, _ROUNDTRIP_TOLERANCE);
        assertApproxEqAbs(_balanceOf(key0.currency1, alice), aliceCurrency1BeforeMint, _ROUNDTRIP_TOLERANCE);
    }

    // ===== Case 3: both currencies are PAs owned by different admins; admin1 (= owner of pa0) calls =====
    // pa0 always cascades happy-path because admin1 controls currency0's compliance list. pa2 is the variable.

    /// @dev Case 3a: LP on both underlyings → both cascade to LP.
    function test_unwindPosition_two_pas_different_admins_routes_both_to_lp(address admin1, address admin2) public {
        _setupUnwindPositionTests(admin1, admin2);

        uint256 aliceCurrency0BeforeMint = _balanceOf(currency0, alice);
        uint256 aliceCurrency2BeforeMint = _balanceOf(currency2, alice);

        uint256 tokenId = lpm.nextTokenId();
        _test_permissioned_mint_allowed_user(key2);

        vm.prank(admin1);
        _unwind(tokenId);

        assertApproxEqAbs(_balanceOf(currency0, alice), aliceCurrency0BeforeMint, _ROUNDTRIP_TOLERANCE);
        assertApproxEqAbs(_balanceOf(currency2, alice), aliceCurrency2BeforeMint, _ROUNDTRIP_TOLERANCE);
    }

    /// @dev Case 3b: LP delisted on currency2 → pa0 → LP, pa2 → admin2 (pa2's admin).
    function test_unwindPosition_two_pas_different_admins_routes_pa2_to_admin2_when_lp_blocked(
        address admin1,
        address admin2
    ) public {
        _setupUnwindPositionTests(admin1, admin2);

        uint256 aliceCurrency0BeforeMint = _balanceOf(currency0, alice);
        uint256 aliceCurrency2BeforeMint = _balanceOf(currency2, alice);
        uint256 admin2Currency2BeforeMint = _balanceOf(currency2, admin2);

        uint256 tokenId = lpm.nextTokenId();
        _test_permissioned_mint_allowed_user(key2);

        uint256 deposited2 = aliceCurrency2BeforeMint - _balanceOf(currency2, alice);

        MockPermissionedToken(Currency.unwrap(currency2)).setTokenAllowlist(alice, false);
        MockPermissionedToken(Currency.unwrap(currency2)).setTokenAllowlist(admin2, true);

        vm.prank(admin1);
        _unwind(tokenId);

        assertApproxEqAbs(_balanceOf(currency0, alice), aliceCurrency0BeforeMint, _ROUNDTRIP_TOLERANCE);
        assertApproxEqAbs(_balanceOf(currency2, admin2) - admin2Currency2BeforeMint, deposited2, _ROUNDTRIP_TOLERANCE);
    }

    /// @dev Case 3c: LP and admin2 delisted on currency2 → pa0 → LP, pa2 → 6909 claim to admin2.
    function test_unwindPosition_two_pas_different_admins_credits_6909_when_lp_and_admin2_blocked(
        address admin1,
        address admin2
    ) public {
        _setupUnwindPositionTests(admin1, admin2);

        uint256 aliceCurrency0BeforeMint = _balanceOf(currency0, alice);
        uint256 aliceCurrency2BeforeMint = _balanceOf(currency2, alice);

        uint256 tokenId = lpm.nextTokenId();
        _test_permissioned_mint_allowed_user(key2);

        uint256 deposited2 = aliceCurrency2BeforeMint - _balanceOf(currency2, alice);

        MockPermissionedToken(Currency.unwrap(currency2)).setTokenAllowlist(alice, false);
        MockPermissionedToken(Currency.unwrap(currency2)).setTokenAllowlist(admin2, false);

        vm.prank(admin1);
        _unwind(tokenId);

        assertApproxEqAbs(_balanceOf(currency0, alice), aliceCurrency0BeforeMint, _ROUNDTRIP_TOLERANCE);
        assertApproxEqAbs(manager.balanceOf(admin2, key2.currency1.toId()), deposited2, _ROUNDTRIP_TOLERANCE);
    }

    /// @dev Non-PA edge case: regular ERC-20 transfer to LP reverts (e.g., LP is blocklisted by the token).
    ///      Cascade falls back to minting a 6909 claim to LP — not to any admin.
    function test_unwindPosition_non_pa_credits_6909_to_lp_when_lp_rejects(address admin1, address admin2) public {
        _setupUnwindPositionTests(admin1, admin2);

        uint256 tokenId = lpm.nextTokenId();
        _test_permissioned_mint_allowed_user(key0); // [pa0, regular]

        uint256 aliceRegularPostMint = _balanceOf(key0.currency1, alice);

        // Force the regular ERC-20's transfer to alice to revert (simulating a blocklist or compliance hook)
        vm.mockCallRevert(
            Currency.unwrap(key0.currency1),
            abi.encodeWithSelector(IERC20.transfer.selector, alice),
            bytes("LP rejects")
        );

        // pa0 leg lands at alice as underlying; regular leg falls back to 6909 mint to alice (asClaim=true)
        vm.expectEmit(true, true, true, false);
        emit CurrencyUnwound(tokenId, key0.currency0, alice, address(0), address(0), 0, false);
        vm.expectEmit(true, true, true, false);
        emit CurrencyUnwound(tokenId, key0.currency1, alice, address(0), address(0), 0, true);
        vm.prank(admin1);
        _unwind(tokenId);

        // alice's regular balance unchanged (transfer was rejected) but she received a 6909 claim instead
        assertEq(_balanceOf(key0.currency1, alice), aliceRegularPostMint);
        assertGt(manager.balanceOf(alice, key0.currency1.toId()), 0);
        // admin1 has no 6909 claim for the regular currency — admins don't custody non-PA value
        assertEq(manager.balanceOf(admin1, key0.currency1.toId()), 0);
    }

    // ===== Auth / either-admin =====

    function test_unwindPosition_reverts_when_caller_is_not_admin(address admin1, address admin2, address notAdmin)
        public
    {
        _setupUnwindPositionTests(admin1, admin2);
        vm.assume(notAdmin != admin1 && notAdmin != admin2);

        uint256 tokenId = lpm.nextTokenId();
        _test_permissioned_mint_allowed_user(key2);

        vm.prank(notAdmin);
        (bool ok, bytes memory data) = address(lpm).call(abi.encodeWithSelector(_UNWIND_SELECTOR, tokenId));
        assertEq(ok, false);
        assertEq(bytes4(data), Unauthorized.selector);
    }

    /// @dev Either PA admin can call `unwindPosition`. With distinct admins, exercise both.
    function test_unwindPosition_either_admin_acts_independently(address admin1, address admin2) public {
        _setupUnwindPositionTests(admin1, admin2);
        vm.assume(admin1 != admin2);

        uint256 tokenId0 = lpm.nextTokenId();
        _test_permissioned_mint_allowed_user(key2);
        uint256 tokenId1 = lpm.nextTokenId();
        _test_permissioned_mint_allowed_user(key2);

        vm.prank(admin1);
        _unwind(tokenId0);
        vm.expectRevert();
        IERC721(address(lpm)).ownerOf(tokenId0);

        vm.prank(admin2);
        _unwind(tokenId1);
        vm.expectRevert();
        IERC721(address(lpm)).ownerOf(tokenId1);
    }

    // ===== withdrawClaim =====

    /// @dev Forces the cascade to the 6909 fallback (LP and admin1 both delisted on currency0), then redeems
    ///      the admin1-held claim via `withdrawClaim` to a fresh `to`.
    function test_withdrawClaim_round_trip(address admin1, address admin2, address to) public {
        _setupUnwindPositionTests(admin1, admin2);
        // `to` must be distinct from existing actors and from action-handler sentinels (MSG_SENDER = 0x1 /
        // ADDRESS_THIS = 0x2 would get remapped by _mapRecipient inside the TAKE action)
        vm.assume(to != address(0));
        vm.assume(to != ActionConstants.MSG_SENDER);
        vm.assume(to != ActionConstants.ADDRESS_THIS);
        vm.assume(to != alice);
        vm.assume(to != admin1);
        vm.assume(to != address(manager));
        vm.assume(to != address(lpm));
        vm.assume(to != address(permissionsAdapter0));
        vm.assume(to != address(permissionsAdapter2));

        uint256 tokenId = lpm.nextTokenId();
        _test_permissioned_mint_allowed_user(key0);

        MockPermissionedToken(Currency.unwrap(currency0)).setTokenAllowlist(alice, false);
        MockPermissionedToken(Currency.unwrap(currency0)).setTokenAllowlist(admin1, false);

        vm.prank(admin1);
        _unwind(tokenId);

        uint256 claim = manager.balanceOf(admin1, key0.currency0.toId());
        assertGt(claim, 0);

        // `to` needs to be on the underlying compliance list to receive the secToken on unwrap
        MockPermissionedToken(Currency.unwrap(currency0)).setAllowlist(to, PermissionFlags.ALL_ALLOWED);

        // admin1 authorizes permPosm to burn its 6909 claims
        vm.prank(admin1);
        manager.setOperator(address(lpm), true);

        uint256 toBefore = _balanceOf(currency0, to);
        vm.expectEmit(true, true, true, true);
        emit ClaimWithdrawn(key0.currency0, admin1, to, claim);
        vm.prank(admin1);
        _withdrawClaim(key0.currency0, claim, to);

        // claim fully consumed; to received exactly `claim` of the underlying
        assertEq(manager.balanceOf(admin1, key0.currency0.toId()), 0);
        assertEq(_balanceOf(currency0, to) - toBefore, claim);
    }

    /// @dev `MSG_SENDER` sentinel must resolve to the action executor in both the underlying delivery and
    ///      the `ClaimWithdrawn` event. Same cascade-to-6909 setup as the round-trip test.
    function test_withdrawClaim_resolves_msg_sender_sentinel() public {
        address admin = makeAddr("WC_ADMIN_MS");
        address other = makeAddr("WC_OTHER_MS");
        _setupUnwindPositionTests(admin, other);

        uint256 tokenId = lpm.nextTokenId();
        _test_permissioned_mint_allowed_user(key0);

        MockPermissionedToken(Currency.unwrap(currency0)).setTokenAllowlist(alice, false);
        MockPermissionedToken(Currency.unwrap(currency0)).setTokenAllowlist(admin, false);

        vm.prank(admin);
        _unwind(tokenId);

        uint256 claim = manager.balanceOf(admin, key0.currency0.toId());
        assertGt(claim, 0);

        // re-list admin so the unwrap on TAKE can deliver underlying back to it
        MockPermissionedToken(Currency.unwrap(currency0)).setAllowlist(admin, PermissionFlags.ALL_ALLOWED);

        vm.prank(admin);
        manager.setOperator(address(lpm), true);

        vm.expectEmit(true, true, true, true);
        emit ClaimWithdrawn(key0.currency0, admin, admin, claim);
        vm.prank(admin);
        _withdrawClaim(key0.currency0, claim, ActionConstants.MSG_SENDER);
    }

    /// @dev `ADDRESS_THIS` sentinel must resolve to the position manager in both the delivery and the event.
    function test_withdrawClaim_resolves_address_this_sentinel() public {
        address admin = makeAddr("WC_ADMIN_AT");
        address other = makeAddr("WC_OTHER_AT");
        _setupUnwindPositionTests(admin, other);

        uint256 tokenId = lpm.nextTokenId();
        _test_permissioned_mint_allowed_user(key0);

        MockPermissionedToken(Currency.unwrap(currency0)).setTokenAllowlist(alice, false);
        MockPermissionedToken(Currency.unwrap(currency0)).setTokenAllowlist(admin, false);

        vm.prank(admin);
        _unwind(tokenId);

        uint256 claim = manager.balanceOf(admin, key0.currency0.toId());
        assertGt(claim, 0);

        // permPosm must be allowed to receive the underlying when the TAKE unwraps into it
        MockPermissionedToken(Currency.unwrap(currency0)).setAllowlist(address(lpm), PermissionFlags.ALL_ALLOWED);

        vm.prank(admin);
        manager.setOperator(address(lpm), true);

        vm.expectEmit(true, true, true, true);
        emit ClaimWithdrawn(key0.currency0, admin, address(lpm), claim);
        vm.prank(admin);
        _withdrawClaim(key0.currency0, claim, ActionConstants.ADDRESS_THIS);
    }

    /// @dev Caller has not authorized permPosm via `setOperator` → BURN_6909 underflows on the allowance check.
    function test_withdrawClaim_reverts_without_operator() public {
        vm.startPrank(alice);
        (bool ok,) = address(lpm).call(abi.encodeWithSelector(_WITHDRAW_CLAIM_SELECTOR, key2.currency0, 1, alice));
        vm.stopPrank();
        assertEq(ok, false);
    }

    /// @dev Caller has authorized permPosm but holds no 6909 balance → BURN_6909 passes auth and underflows on
    ///      the balance subtraction.
    function test_withdrawClaim_reverts_without_balance() public {
        vm.prank(alice);
        manager.setOperator(address(lpm), true);

        vm.startPrank(alice);
        (bool ok,) = address(lpm).call(abi.encodeWithSelector(_WITHDRAW_CLAIM_SELECTOR, key2.currency0, 1, alice));
        vm.stopPrank();
        assertEq(ok, false);
    }

    /// @dev BURN_6909 must reject a `from` that is not the action executor, even when the holder has authorized
    ///      permPosm as a PoolManager operator. Otherwise a third party could drain the claim via raw
    ///      `modifyLiquidities([BURN_6909(currency, victim, amount), TAKE(currency, attacker, amount)])`.
    function test_burn6909_reverts_when_from_is_not_executor(address admin1, address admin2) public {
        _setupUnwindPositionTests(admin1, admin2);
        address bob = makeAddr("BOB");
        vm.assume(bob != admin1 && bob != admin2 && bob != alice);

        // produce a 6909 claim held by admin1 via the unwind cascade
        uint256 tokenId = lpm.nextTokenId();
        _test_permissioned_mint_allowed_user(key0);
        MockPermissionedToken(Currency.unwrap(currency0)).setTokenAllowlist(alice, false);
        MockPermissionedToken(Currency.unwrap(currency0)).setTokenAllowlist(admin1, false);
        vm.prank(admin1);
        _unwind(tokenId);

        uint256 claim = manager.balanceOf(admin1, key0.currency0.toId());
        assertGt(claim, 0);

        // admin1 follows the documented withdrawClaim approval pattern
        vm.prank(admin1);
        manager.setOperator(address(lpm), true);

        bytes memory actions = abi.encodePacked(uint8(Actions.BURN_6909), uint8(Actions.TAKE));
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(key0.currency0, admin1, claim);
        params[1] = abi.encode(key0.currency0, bob, claim);

        vm.prank(bob);
        vm.expectRevert(Unauthorized.selector);
        lpm.modifyLiquidities(abi.encode(actions, params), block.timestamp + 1);
    }

    /// @dev TAKE(adapter, ADDRESS_THIS) leaves the POSM holding the underlying permissioned token
    /// (because PermissionsAdapter._update auto-unwraps on transfer out of the PoolManager).
    /// SWEEP(adapter, ...) must therefore resolve to and transfer the underlying — not the adapter —
    /// or else the underlying is stranded and sweepable by a later caller.
    function test_sweep_adapterCurrency_transfersUnderlyingToRecipient() public {
        Currency adapterCurrency = key0.currency0;
        Currency underlying = getPermissionedCurrency(adapterCurrency);

        PositionConfig memory config = PositionConfig({poolKey: key0, tickLower: -120, tickUpper: 120});
        uint256 liquidityToAdd = 100e18;
        uint256 tokenId = lpm.nextTokenId();
        mint(config, liquidityToAdd, address(this), ZERO_BYTES);

        uint256 recipientUnderlyingBefore = underlying.balanceOf(alice);
        uint256 recipientAdapterBefore = adapterCurrency.balanceOf(alice);

        // DECREASE to create a positive delta, then TAKE(adapter, ADDRESS_THIS) which routes the
        // underlying into POSM via the adapter unwrap, then SWEEP(adapter, alice).
        Plan memory planner = Planner.init();
        planner.add(
            Actions.DECREASE_LIQUIDITY,
            abi.encode(tokenId, liquidityToAdd, MIN_SLIPPAGE_DECREASE, MIN_SLIPPAGE_DECREASE, ZERO_BYTES)
        );
        planner.add(Actions.TAKE, abi.encode(adapterCurrency, ActionConstants.ADDRESS_THIS, ActionConstants.OPEN_DELTA));
        planner.add(Actions.TAKE, abi.encode(key0.currency1, ActionConstants.MSG_SENDER, ActionConstants.OPEN_DELTA));
        planner.add(Actions.SWEEP, abi.encode(adapterCurrency, alice));

        lpm.modifyLiquidities(planner.encode(), _deadline);

        // Alice received the underlying token, not the adapter token.
        assertGt(underlying.balanceOf(alice), recipientUnderlyingBefore, "recipient did not receive underlying");
        assertEq(
            adapterCurrency.balanceOf(alice), recipientAdapterBefore, "recipient should not receive adapter tokens"
        );
        // POSM should not be left holding either the underlying or the adapter.
        assertEq(underlying.balanceOf(address(lpm)), 0, "underlying stranded in POSM");
        assertEq(adapterCurrency.balanceOf(address(lpm)), 0, "adapter stranded in POSM");
    }

    /// @dev Second call to SWEEP with the adapter currency must be a no-op — the underlying
    /// has already been forwarded on the first sweep.
    function test_sweep_adapterCurrency_secondSweepTransfersNothing() public {
        Currency adapterCurrency = key0.currency0;
        Currency underlying = getPermissionedCurrency(adapterCurrency);

        PositionConfig memory config = PositionConfig({poolKey: key0, tickLower: -120, tickUpper: 120});
        uint256 liquidityToAdd = 100e18;
        uint256 tokenId = lpm.nextTokenId();
        mint(config, liquidityToAdd, address(this), ZERO_BYTES);

        uint256 aliceBefore = underlying.balanceOf(alice);
        uint256 selfBefore = underlying.balanceOfSelf();

        Plan memory planner = Planner.init();
        planner.add(
            Actions.DECREASE_LIQUIDITY,
            abi.encode(tokenId, liquidityToAdd, MIN_SLIPPAGE_DECREASE, MIN_SLIPPAGE_DECREASE, ZERO_BYTES)
        );
        planner.add(Actions.TAKE, abi.encode(adapterCurrency, ActionConstants.ADDRESS_THIS, ActionConstants.OPEN_DELTA));
        planner.add(Actions.TAKE, abi.encode(key0.currency1, ActionConstants.MSG_SENDER, ActionConstants.OPEN_DELTA));
        planner.add(Actions.SWEEP, abi.encode(adapterCurrency, alice));
        // Second sweep goes to the test contract (also allowlisted) and should move nothing
        // since the POSM's underlying balance was fully drained by the first sweep.
        planner.add(Actions.SWEEP, abi.encode(adapterCurrency, address(this)));

        lpm.modifyLiquidities(planner.encode(), _deadline);

        assertGt(underlying.balanceOf(alice), aliceBefore, "first recipient received nothing");
        assertEq(underlying.balanceOfSelf(), selfBefore, "second sweep should transfer nothing");
        assertEq(adapterCurrency.balanceOfSelf(), 0, "second sweep should not transfer adapter");
    }

    /// @dev Sweeping a non-permissioned currency is unchanged: it still transfers whatever balance
    /// of that currency POSM happens to hold.
    function test_sweep_nonPermissionedCurrency_stillTransfersBalance() public {
        Currency nonPermissioned = key0.currency1;
        uint256 amount = 123 ether;
        nonPermissioned.transfer(address(lpm), amount);

        address recipient = makeAddr("RECIPIENT");
        uint256 recipientBefore = nonPermissioned.balanceOf(recipient);

        Plan memory planner = Planner.init();
        planner.add(Actions.SWEEP, abi.encode(nonPermissioned, recipient));
        lpm.modifyLiquidities(planner.encode(), _deadline);

        assertEq(nonPermissioned.balanceOf(recipient) - recipientBefore, amount);
        assertEq(nonPermissioned.balanceOf(address(lpm)), 0);
    }

    // ===== Subscriber DoS protection on unwindPosition =====

    /// @dev Admin force-exit succeeds even when the LP attached a subscriber that reverts on
    ///      `notifyUnsubscribe`. The revert is gas-capped + try/catch'd inside `_unsubscribe`.
    function test_unwindPosition_with_unsubscribe_reverting_subscriber_succeeds() public {
        uint256 tokenId = lpm.nextTokenId();
        _test_permissioned_mint_allowed_user(key2);

        MockUnsubscribeRevertingSubscriber sub = new MockUnsubscribeRevertingSubscriber();
        vm.prank(alice);
        INotifier(address(lpm)).subscribe(tokenId, address(sub), "");
        assertEq(address(INotifier(address(lpm)).subscriber(tokenId)), address(sub));

        // address(this) is admin of both adapters (default setUp)
        (bool ok,) = address(lpm).call(abi.encodeWithSelector(_UNWIND_SELECTOR, tokenId));
        assertEq(ok, true);

        // subscriber detached, NFT burned
        assertEq(address(INotifier(address(lpm)).subscriber(tokenId)), address(0));
        vm.expectRevert();
        IERC721(address(lpm)).ownerOf(tokenId);
    }

    /// @dev Admin force-exit succeeds even when the LP grants operator approval to a malicious
    ///      reentrant subscriber that tries to re-attach a fresh subscriber during
    ///      `notifyUnsubscribe`. The re-entry is blocked by `subscribe`'s `onlyIfPoolManagerLocked`
    ///      modifier (we're inside an active unlock callback when `_unsubscribe` runs).
    function test_unwindPosition_with_reentrant_subscriber_blocks_reentry() public {
        uint256 tokenId = lpm.nextTokenId();
        _test_permissioned_mint_allowed_user(key2);

        // The would-be replacement subscriber. If reentry succeeded, this would be attached
        // and its `notifyBurn` revert would brick the burn.
        MockBurnRevertingSubscriber replacement = new MockBurnRevertingSubscriber();

        // The malicious subscriber that the LP attaches. On notifyUnsubscribe it tries to
        // re-attach `replacement` via posm.subscribe.
        MockReentrantSubscriber sub = new MockReentrantSubscriber(INotifier(address(lpm)), address(replacement));

        vm.prank(alice);
        INotifier(address(lpm)).subscribe(tokenId, address(sub), "");
        assertEq(address(INotifier(address(lpm)).subscriber(tokenId)), address(sub));

        // The reentry path requires the subscriber to be authorized to call posm.subscribe.
        // LP grants operator approval — this is the setup we're testing the defense against.
        vm.prank(alice);
        IERC721(address(lpm)).setApprovalForAll(address(sub), true);

        (bool ok,) = address(lpm).call(abi.encodeWithSelector(_UNWIND_SELECTOR, tokenId));
        assertEq(ok, true);

        // Subscriber fully detached — no re-attach happened, despite the reentry attempt.
        assertEq(address(INotifier(address(lpm)).subscriber(tokenId)), address(0));
        vm.expectRevert();
        IERC721(address(lpm)).ownerOf(tokenId);
    }

    /// @dev LP-initiated burn semantics are preserved: a subscriber that reverts on `notifyBurn`
    ///      still propagates the revert when the LP burns their own position via BURN_POSITION.
    function test_burn_lp_with_burn_reverting_subscriber_still_reverts() public {
        uint256 tokenId = lpm.nextTokenId();
        _test_permissioned_mint_allowed_user(key2);

        MockBurnRevertingSubscriber sub = new MockBurnRevertingSubscriber();
        vm.prank(alice);
        INotifier(address(lpm)).subscribe(tokenId, address(sub), "");

        PositionConfig memory config = PositionConfig({poolKey: key2, tickLower: -120, tickUpper: 120});

        vm.prank(alice);
        vm.expectRevert();
        burn(tokenId, config, ZERO_BYTES);
    }

    // ===== Action handler authorization =====

    /// @dev A third party cannot detach a subscriber via the UNSUBSCRIBE action.
    function test_handleAction_unsubscribe_reverts_for_unauthorized_caller() public {
        uint256 tokenId = lpm.nextTokenId();
        _test_permissioned_mint_allowed_user(key2);

        MockSubscriber sub = new MockSubscriber(IPositionManager(address(lpm)));
        vm.prank(alice);
        INotifier(address(lpm)).subscribe(tokenId, address(sub), "");

        Plan memory planner = Planner.init();
        planner.add(Actions.UNSUBSCRIBE, abi.encode(tokenId));
        bytes memory calls = planner.encode();

        vm.prank(unauthorizedUser);
        vm.expectRevert(abi.encodeWithSelector(IPositionManager.NotApproved.selector, unauthorizedUser));
        lpm.modifyLiquidities(calls, block.timestamp + 1);

        // subscriber stays attached
        assertEq(address(INotifier(address(lpm)).subscriber(tokenId)), address(sub));
    }

    /// @dev The position owner can use the UNSUBSCRIBE action directly.
    function test_handleAction_unsubscribe_succeeds_for_owner() public {
        uint256 tokenId = lpm.nextTokenId();
        _test_permissioned_mint_allowed_user(key2);

        MockSubscriber sub = new MockSubscriber(IPositionManager(address(lpm)));
        vm.prank(alice);
        INotifier(address(lpm)).subscribe(tokenId, address(sub), "");

        Plan memory planner = Planner.init();
        planner.add(Actions.UNSUBSCRIBE, abi.encode(tokenId));
        bytes memory calls = planner.encode();

        vm.prank(alice);
        lpm.modifyLiquidities(calls, block.timestamp + 1);

        assertEq(address(INotifier(address(lpm)).subscriber(tokenId)), address(0));
    }

    /// @dev UNWIND_WITH_FALLBACK is restricted to permissions-adapter admins of the position's pool.
    function test_handleAction_unwindWithFallback_reverts_for_non_admin() public {
        uint256 tokenId = lpm.nextTokenId();
        _test_permissioned_mint_allowed_user(key2);

        Plan memory planner = Planner.init();
        planner.add(Actions.UNWIND_WITH_FALLBACK, abi.encode(key2, key2.currency0, unauthorizedUser, tokenId));
        bytes memory calls = planner.encode();

        vm.prank(unauthorizedUser);
        vm.expectRevert(Unauthorized.selector);
        lpm.modifyLiquidities(calls, block.timestamp + 1);
    }

    /// @dev UNWIND_WITH_FALLBACK rejects a currency that does not belong to the supplied PoolKey,
    ///      preventing spoofed `CurrencyUnwound` events even from a legitimate adapter admin.
    function test_handleAction_unwindWithFallback_reverts_for_mismatched_currency() public {
        uint256 tokenId = lpm.nextTokenId();
        _test_permissioned_mint_allowed_user(key2);

        // currency1 is the non-permissioned ERC-20 and is not part of key2.
        Plan memory planner = Planner.init();
        planner.add(Actions.UNWIND_WITH_FALLBACK, abi.encode(key2, currency1, alice, tokenId));
        bytes memory calls = planner.encode();

        // address(this) is the admin of both adapters in default setUp.
        vm.expectRevert(Unauthorized.selector);
        lpm.modifyLiquidities(calls, block.timestamp + 1);
    }
}
