// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

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

import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {IERC721} from "forge-std/interfaces/IERC721.sol";

import {IPositionManager} from "../../src/interfaces/IPositionManager.sol";
import {Actions} from "../../src/libraries/Actions.sol";
import {DeltaResolver} from "../../src/base/DeltaResolver.sol";
import {PositionConfig} from "../shared/PositionConfig.sol";
import {SlippageCheck} from "../../src/libraries/SlippageCheck.sol";
import {BaseActionsRouter} from "../../src/base/BaseActionsRouter.sol";
import {ActionConstants} from "../../src/libraries/ActionConstants.sol";

import {LiquidityFuzzers} from "../shared/fuzz/LiquidityFuzzers.sol";
import {Planner, Plan} from "../shared/Planner.sol";
import {PosmTestSetup} from "../shared/PosmTestSetup.sol";
import {ReentrantToken} from "../mocks/ReentrantToken.sol";
import {ReentrancyLock} from "../../src/base/ReentrancyLock.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

contract PositionManagerTest is Test, PosmTestSetup, LiquidityFuzzers {
    using FixedPointMathLib for uint256;
    using StateLibrary for IPoolManager;

    PoolId poolId;
    address alice = makeAddr("ALICE");

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();

        // This is needed to receive return deltas from modifyLiquidity calls.
        deployPosmHookSavesDelta();

        (key, poolId) = initPool(currency0, currency1, IHooks(hook), 3000, SQRT_PRICE_1_1);

        // Requires currency0 and currency1 to be set in base Deployers contract.
        deployAndApprovePosm(manager);

        seedBalance(alice);
        approvePosmFor(alice);
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

        (key, poolId) = initPool(currency0, currency1, IHooks(address(0)), 3000, SQRT_PRICE_1_1);

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

        uint256 tokenId = lpm.nextTokenId();
        mint(config, liquidityToAdd, ActionConstants.MSG_SENDER, ZERO_BYTES);
        BalanceDelta delta = getLastDelta();

        assertEq(tokenId, 1);
        assertEq(lpm.nextTokenId(), 2);
        assertEq(IERC721(address(lpm)).ownerOf(tokenId), address(this));

        uint256 liquidity = lpm.getPositionLiquidity(tokenId);

        assertEq(liquidity, uint256(params.liquidityDelta));
        assertEq(balance0Before - currency0.balanceOfSelf(), uint256(int256(-delta.amount0())), "incorrect amount0");
        assertEq(balance1Before - currency1.balanceOfSelf(), uint256(int256(-delta.amount1())), "incorrect amount1");
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

        uint256 tokenId = lpm.nextTokenId();
        mint(config, liquidityToAdd, ActionConstants.MSG_SENDER, ZERO_BYTES);
        BalanceDelta delta = getLastDelta();

        uint256 balance0After = currency0.balanceOfSelf();
        uint256 balance1After = currency1.balanceOfSelf();

        assertEq(tokenId, 1);
        assertEq(IERC721(address(lpm)).ownerOf(1), address(this));

        assertEq(uint256(int256(-delta.amount0())), amount0Desired);
        assertEq(uint256(int256(-delta.amount1())), amount1Desired);
        assertEq(balance0Before - balance0After, uint256(int256(-delta.amount0())));
        assertEq(balance1Before - balance1After, uint256(int256(-delta.amount1())));
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

        uint256 tokenId = lpm.nextTokenId();
        // mint to specific recipient, not using the recipient constants
        mint(config, liquidityToAdd, alice, ZERO_BYTES);
        BalanceDelta delta = getLastDelta();

        uint256 balance0After = currency0.balanceOfSelf();
        uint256 balance1After = currency1.balanceOfSelf();

        assertEq(tokenId, 1);
        assertEq(IERC721(address(lpm)).ownerOf(1), alice);

        assertEq(uint256(int256(-delta.amount0())), amount0Desired);
        assertEq(uint256(int256(-delta.amount1())), amount1Desired);
        assertEq(balance0Before - balance0After, uint256(int256(-delta.amount0())));
        assertEq(balance1Before - balance1After, uint256(int256(-delta.amount1())));
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
        mint(config, liquidityToAdd, alice, ZERO_BYTES);
        BalanceDelta delta = getLastDelta();

        assertEq(tokenId, 1);
        assertEq(IERC721(address(lpm)).ownerOf(tokenId), alice);

        // alice was not the payer
        assertEq(balance0Before - currency0.balanceOfSelf(), uint256(int256(-delta.amount0())));
        assertEq(balance1Before - currency1.balanceOfSelf(), uint256(int256(-delta.amount1())));
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

        Currency negativeDeltaCurrency = currency0;
        // because we're fuzzing the range, single-sided mint with currency1 means currency0Delta = 0 and currency1Delta < 0
        if (config.tickUpper <= 0) {
            negativeDeltaCurrency = currency1;
        }

        vm.expectRevert(abi.encodeWithSelector(DeltaResolver.DeltaNotPositive.selector, negativeDeltaCurrency));
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
        BalanceDelta delta = getLastDelta();
        assertEq(uint256(int256(-delta.amount0())), slippage);
        assertEq(uint256(int256(-delta.amount1())), slippage);
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
        swap(key, true, -1e18, ZERO_BYTES);

        vm.expectRevert(
            abi.encodeWithSelector(SlippageCheck.MaximumAmountExceeded.selector, slippage, 1199947202932782783)
        );
        lpm.modifyLiquidities(calls, _deadline);
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

        decreaseLiquidity(tokenId, config, liquidity, ZERO_BYTES);
        BalanceDelta deltaDecrease = getLastDelta();
        uint256 numDeltas = hook.numberDeltasReturned();
        // No decrease/modifyLiq call will actually happen on the call to burn so the deltas array will be the same length.
        burn(tokenId, config, ZERO_BYTES);
        assertEq(numDeltas, hook.numberDeltasReturned());

        liquidity = lpm.getPositionLiquidity(tokenId);

        assertEq(liquidity, 0);

        assertEq(currency0.balanceOfSelf(), balance0BeforeBurn + uint256(int256(deltaDecrease.amount0())));
        assertEq(currency1.balanceOfSelf(), balance1BeforeBurn + uint256(uint128(deltaDecrease.amount1())));

        // 721 will revert if the token does not exist
        vm.expectRevert();
        IERC721(address(lpm)).ownerOf(1);

        // no tokens were lost, TODO: fuzzer showing off by 1 sometimes
        // Potentially because we round down in core. I believe this is known in V3. But let's check!
        assertApproxEqAbs(currency0.balanceOfSelf(), balance0Start, 1 wei);
        assertApproxEqAbs(currency1.balanceOfSelf(), balance1Start, 1 wei);
    }

    function test_fuzz_burn_nonEmptyPosition(ModifyLiquidityParams memory params) public {
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

        (uint160 sqrtPriceX96,,,) = manager.getSlot0(key.toId());
        (uint256 amount0, uint256 amount1) = LiquidityAmounts.getAmountsForLiquidity(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(params.tickLower),
            TickMath.getSqrtPriceAtTick(params.tickUpper),
            uint128(int128(params.liquidityDelta))
        );

        // burn liquidity
        uint256 balance0BeforeBurn = currency0.balanceOfSelf();
        uint256 balance1BeforeBurn = currency1.balanceOfSelf();

        burn(tokenId, config, ZERO_BYTES);
        BalanceDelta deltaBurn = getLastDelta();

        assertEq(uint256(int256(deltaBurn.amount0())), amount0);
        assertEq(uint256(int256(deltaBurn.amount1())), amount1);

        liquidity = lpm.getPositionLiquidity(tokenId);

        assertEq(liquidity, 0);

        assertEq(currency0.balanceOfSelf(), balance0BeforeBurn + uint256(int256(deltaBurn.amount0())));
        assertEq(currency1.balanceOfSelf(), balance1BeforeBurn + uint256(uint128(deltaBurn.amount1())));

        // OZ 721 will revert if the token does not exist
        vm.expectRevert();
        IERC721(address(lpm)).ownerOf(1);

        // no tokens were lost, TODO: fuzzer showing off by 1 sometimes
        // Potentially because we round down in core. I believe this is known in V3. But let's check!
        assertApproxEqAbs(currency0.balanceOfSelf(), balance0Start, 1 wei);
        assertApproxEqAbs(currency1.balanceOfSelf(), balance1Start, 1 wei);
    }

    function test_burn_slippage_revertAmount0() public {
        PositionConfig memory config = PositionConfig({poolKey: key, tickLower: -120, tickUpper: 120});
        uint256 tokenId = lpm.nextTokenId();
        mint(config, 1e18, ActionConstants.MSG_SENDER, ZERO_BYTES);
        BalanceDelta delta = getLastDelta();
        uint128 amount0 = uint128(-delta.amount0());

        bytes memory calls = getBurnEncoded(tokenId, config, amount0 + 1 wei, MIN_SLIPPAGE_DECREASE, ZERO_BYTES);
        vm.expectRevert(
            abi.encodeWithSelector(SlippageCheck.MinimumAmountInsufficient.selector, amount0 + 1, amount0 - 1)
        );
        lpm.modifyLiquidities(calls, _deadline);
    }

    function test_burn_slippage_revertAmount1() public {
        PositionConfig memory config = PositionConfig({poolKey: key, tickLower: -120, tickUpper: 120});
        uint256 tokenId = lpm.nextTokenId();
        mint(config, 1e18, ActionConstants.MSG_SENDER, ZERO_BYTES);
        BalanceDelta delta = getLastDelta();
        uint128 amount1 = uint128(-delta.amount1());

        bytes memory calls = getBurnEncoded(tokenId, config, MIN_SLIPPAGE_DECREASE, amount1 + 1 wei, ZERO_BYTES);

        // reverts on amount1, because the swap sent token0 into the pool and took token1
        vm.expectRevert(
            abi.encodeWithSelector(SlippageCheck.MinimumAmountInsufficient.selector, amount1 + 1, amount1 - 1)
        );
        lpm.modifyLiquidities(calls, _deadline);
    }

    function test_burn_slippage_exactDoesNotRevert() public {
        PositionConfig memory config = PositionConfig({poolKey: key, tickLower: -120, tickUpper: 120});
        uint256 tokenId = lpm.nextTokenId();
        mint(config, 1e18, ActionConstants.MSG_SENDER, ZERO_BYTES);
        BalanceDelta delta = getLastDelta();

        // TODO: why does burning a newly minted position return original delta - 1 wei?
        bytes memory calls = getBurnEncoded(
            tokenId, config, uint128(-delta.amount0()) - 1 wei, uint128(-delta.amount1()) - 1 wei, ZERO_BYTES
        );
        lpm.modifyLiquidities(calls, _deadline);
        BalanceDelta burnDelta = getLastDelta();

        assertApproxEqAbs(-delta.amount0(), burnDelta.amount0(), 1 wei);
        assertApproxEqAbs(-delta.amount1(), burnDelta.amount1(), 1 wei);
    }

    function test_burn_slippage_revert_swap() public {
        // swapping will cause a slippage revert
        PositionConfig memory config = PositionConfig({poolKey: key, tickLower: -120, tickUpper: 120});
        uint256 tokenId = lpm.nextTokenId();
        mint(config, 1e18, ActionConstants.MSG_SENDER, ZERO_BYTES);
        BalanceDelta delta = getLastDelta();
        uint128 amount1 = uint128(-delta.amount1());

        bytes memory calls =
            getBurnEncoded(tokenId, config, uint128(-delta.amount0()) - 1 wei, amount1 - 1 wei, ZERO_BYTES);

        // swap to move the price and cause a slippage revert
        swap(key, true, -1e18, ZERO_BYTES);

        vm.expectRevert(abi.encodeWithSelector(SlippageCheck.MinimumAmountInsufficient.selector, amount1 - 1, 0));
        lpm.modifyLiquidities(calls, _deadline);
    }

    function test_fuzz_decreaseLiquidity(ModifyLiquidityParams memory params, uint256 decreaseLiquidityDelta) public {
        uint256 tokenId;
        (tokenId, params) = addFuzzyLiquidity(lpm, ActionConstants.MSG_SENDER, key, params, SQRT_PRICE_1_1, ZERO_BYTES);
        decreaseLiquidityDelta = uint256(bound(int256(decreaseLiquidityDelta), 0, params.liquidityDelta));

        PositionConfig memory config =
            PositionConfig({poolKey: key, tickLower: params.tickLower, tickUpper: params.tickUpper});

        uint256 balance0Before = currency0.balanceOfSelf();
        uint256 balance1Before = currency1.balanceOfSelf();
        decreaseLiquidity(tokenId, config, decreaseLiquidityDelta, ZERO_BYTES);
        BalanceDelta delta = getLastDelta();

        uint256 liquidity = lpm.getPositionLiquidity(tokenId);
        assertEq(liquidity, uint256(params.liquidityDelta) - decreaseLiquidityDelta);

        assertEq(currency0.balanceOfSelf(), balance0Before + uint256(uint128(delta.amount0())));
        assertEq(currency1.balanceOfSelf(), balance1Before + uint256(uint128(delta.amount1())));
    }

    /// @dev Clearing on decrease liquidity is allowed
    function test_fuzz_decreaseLiquidity_clear(ModifyLiquidityParams memory params, uint256 decreaseLiquidityDelta)
        public
    {
        uint256 tokenId;
        (tokenId, params) = addFuzzyLiquidity(lpm, address(this), key, params, SQRT_PRICE_1_1, ZERO_BYTES);
        decreaseLiquidityDelta = uint256(bound(int256(decreaseLiquidityDelta), 0, params.liquidityDelta));

        uint256 balance0Before = currency0.balanceOfSelf();
        uint256 balance1Before = currency1.balanceOfSelf();

        // Clearing is allowed on decrease liquidity
        Plan memory planner = Planner.init();
        planner.add(
            Actions.DECREASE_LIQUIDITY,
            abi.encode(tokenId, decreaseLiquidityDelta, MIN_SLIPPAGE_DECREASE, MIN_SLIPPAGE_DECREASE, ZERO_BYTES)
        );
        planner.add(Actions.CLEAR_OR_TAKE, abi.encode(key.currency0, type(uint256).max));
        planner.add(Actions.CLEAR_OR_TAKE, abi.encode(key.currency1, type(uint256).max));
        bytes memory calls = planner.encode();

        lpm.modifyLiquidities(calls, _deadline);

        uint256 liquidity = lpm.getPositionLiquidity(tokenId);
        assertEq(liquidity, uint256(params.liquidityDelta) - decreaseLiquidityDelta);

        // did not recieve tokens, as they were forfeited with CLEAR
        assertEq(currency0.balanceOfSelf(), balance0Before);
        assertEq(currency1.balanceOfSelf(), balance1Before);
    }

    /// @dev Clearing on decrease will take tokens if the amount exceeds the clear limit
    function test_fuzz_decreaseLiquidity_clearExceedsThenTake(ModifyLiquidityParams memory params) public {
        // use fuzzer for tick range
        params = createFuzzyLiquidityParams(key, params, SQRT_PRICE_1_1);
        vm.assume(params.tickLower < 0 && 0 < params.tickUpper); // require two-sided liquidity

        PositionConfig memory config =
            PositionConfig({poolKey: key, tickLower: params.tickLower, tickUpper: params.tickUpper});

        uint256 liquidityToAdd = 1e18;
        uint256 liquidityToRemove = bound(liquidityToAdd, liquidityToAdd / 1000, liquidityToAdd);
        uint256 tokenId = lpm.nextTokenId();
        mint(config, 1e18, address(this), ZERO_BYTES);

        (uint256 amount0, uint256 amount1) = LiquidityAmounts.getAmountsForLiquidity(
            SQRT_PRICE_1_1,
            TickMath.getSqrtPriceAtTick(config.tickLower),
            TickMath.getSqrtPriceAtTick(config.tickUpper),
            uint128(liquidityToRemove)
        );

        Plan memory planner = Planner.init();
        planner.add(
            Actions.DECREASE_LIQUIDITY,
            abi.encode(tokenId, liquidityToRemove, MIN_SLIPPAGE_DECREASE, MIN_SLIPPAGE_DECREASE, ZERO_BYTES)
        );
        planner.add(Actions.CLEAR_OR_TAKE, abi.encode(key.currency0, amount0 - 1 wei));
        planner.add(Actions.CLEAR_OR_TAKE, abi.encode(key.currency1, amount1 - 1 wei));
        bytes memory calls = planner.encode();

        uint256 balance0Before = currency0.balanceOfSelf();
        uint256 balance1Before = currency1.balanceOfSelf();

        // expect to take the tokens
        lpm.modifyLiquidities(calls, _deadline);
        BalanceDelta delta = getLastDelta();

        // amount exceeded clear limit, so we should have the tokens
        assertEq(uint128(delta.amount0()), amount0);
        assertEq(uint128(delta.amount1()), amount1);
        assertEq(currency0.balanceOfSelf(), balance0Before + amount0);
        assertEq(currency1.balanceOfSelf(), balance1Before + amount1);
    }

    function test_decreaseLiquidity_collectFees(ModifyLiquidityParams memory params, uint256 decreaseLiquidityDelta)
        public
    {
        uint256 tokenId;
        (tokenId, params) = addFuzzyLiquidity(lpm, ActionConstants.MSG_SENDER, key, params, SQRT_PRICE_1_1, ZERO_BYTES);
        vm.assume(params.tickLower < 0 && 0 < params.tickUpper); // require two-sided liquidity
        decreaseLiquidityDelta = bound(decreaseLiquidityDelta, 1, uint256(params.liquidityDelta));

        PositionConfig memory config =
            PositionConfig({poolKey: key, tickLower: params.tickLower, tickUpper: params.tickUpper});

        // donate to generate fee revenue
        uint256 feeRevenue0 = 1e18;
        uint256 feeRevenue1 = 0.1e18;
        donateRouter.donate(key, feeRevenue0, feeRevenue1, ZERO_BYTES);

        uint256 balance0Before = currency0.balanceOfSelf();
        uint256 balance1Before = currency1.balanceOfSelf();
        decreaseLiquidity(tokenId, config, decreaseLiquidityDelta, ZERO_BYTES);

        uint256 liquidity = lpm.getPositionLiquidity(tokenId);

        assertEq(liquidity, uint256(params.liquidityDelta) - decreaseLiquidityDelta);

        (uint256 amount0, uint256 amount1) = LiquidityAmounts.getAmountsForLiquidity(
            SQRT_PRICE_1_1,
            TickMath.getSqrtPriceAtTick(config.tickLower),
            TickMath.getSqrtPriceAtTick(config.tickUpper),
            uint128(decreaseLiquidityDelta)
        );

        // claimed both principal liquidity and fee revenue
        assertApproxEqAbs(currency0.balanceOfSelf() - balance0Before, amount0 + feeRevenue0, 1 wei);
        assertApproxEqAbs(currency1.balanceOfSelf() - balance1Before, amount1 + feeRevenue1, 1 wei);
    }

    function test_decreaseLiquidity_slippage_revertAmount0() public {
        PositionConfig memory config = PositionConfig({poolKey: key, tickLower: -120, tickUpper: 120});
        uint256 tokenId = lpm.nextTokenId();
        mint(config, 1e18, ActionConstants.MSG_SENDER, ZERO_BYTES);
        BalanceDelta delta = getLastDelta();
        uint128 amount0Delta = uint128(-delta.amount0());

        bytes memory calls =
            getDecreaseEncoded(tokenId, config, 1e18, amount0Delta + 1, MIN_SLIPPAGE_DECREASE, ZERO_BYTES);
        vm.expectRevert(
            abi.encodeWithSelector(SlippageCheck.MinimumAmountInsufficient.selector, amount0Delta + 1, amount0Delta - 1)
        );
        lpm.modifyLiquidities(calls, _deadline);
    }

    function test_decreaseLiquidity_slippage_revertAmount1() public {
        PositionConfig memory config = PositionConfig({poolKey: key, tickLower: -120, tickUpper: 120});
        uint256 tokenId = lpm.nextTokenId();
        mint(config, 1e18, ActionConstants.MSG_SENDER, ZERO_BYTES);
        BalanceDelta delta = getLastDelta();
        uint128 amount1Delta = uint128(-delta.amount0());

        bytes memory calls =
            getDecreaseEncoded(tokenId, config, 1e18, MIN_SLIPPAGE_DECREASE, amount1Delta + 1 wei, ZERO_BYTES);
        vm.expectRevert(
            abi.encodeWithSelector(SlippageCheck.MinimumAmountInsufficient.selector, amount1Delta + 1, amount1Delta - 1)
        );
        lpm.modifyLiquidities(calls, _deadline);
    }

    function test_decreaseLiquidity_slippage_exactDoesNotRevert() public {
        PositionConfig memory config = PositionConfig({poolKey: key, tickLower: -120, tickUpper: 120});
        uint256 tokenId = lpm.nextTokenId();
        mint(config, 1e18, ActionConstants.MSG_SENDER, ZERO_BYTES);
        BalanceDelta delta = getLastDelta();

        // TODO: why does decreasing a newly minted position return original delta - 1 wei?
        bytes memory calls = getDecreaseEncoded(
            tokenId, config, 1e18, uint128(-delta.amount0()) - 1 wei, uint128(-delta.amount1()) - 1 wei, ZERO_BYTES
        );
        lpm.modifyLiquidities(calls, _deadline);
        BalanceDelta decreaseDelta = getLastDelta();

        // TODO: why does decreasing a newly minted position return original delta - 1 wei?
        assertApproxEqAbs(-delta.amount0(), decreaseDelta.amount0(), 1 wei);
        assertApproxEqAbs(-delta.amount1(), decreaseDelta.amount1(), 1 wei);
    }

    function test_decreaseLiquidity_slippage_revert_swap() public {
        // swapping will cause a slippage revert
        PositionConfig memory config = PositionConfig({poolKey: key, tickLower: -120, tickUpper: 120});
        uint256 tokenId = lpm.nextTokenId();
        mint(config, 1e18, ActionConstants.MSG_SENDER, ZERO_BYTES);
        BalanceDelta delta = getLastDelta();
        uint128 amount1 = uint128(-delta.amount1());

        bytes memory calls =
            getDecreaseEncoded(tokenId, config, 1e18, uint128(-delta.amount0()) - 1 wei, amount1 - 1 wei, ZERO_BYTES);

        // swap to move the price and cause a slippage revert
        swap(key, true, -1e18, ZERO_BYTES);

        // reverts on amount1, because the swap sent token0 into the pool and took token1
        vm.expectRevert(abi.encodeWithSelector(SlippageCheck.MinimumAmountInsufficient.selector, amount1 - 1, 0));
        lpm.modifyLiquidities(calls, _deadline);
    }

    function test_fuzz_decreaseLiquidity_assertCollectedBalance(
        ModifyLiquidityParams memory params,
        uint256 decreaseLiquidityDelta
    ) public {
        uint256 tokenId;
        (tokenId, params) = addFuzzyLiquidity(lpm, ActionConstants.MSG_SENDER, key, params, SQRT_PRICE_1_1, ZERO_BYTES);
        vm.assume(params.tickLower < 0 && 0 < params.tickUpper); // require two-sided liquidity
        vm.assume(0 < decreaseLiquidityDelta);
        vm.assume(decreaseLiquidityDelta < uint256(type(int256).max));
        vm.assume(int256(decreaseLiquidityDelta) <= params.liquidityDelta);

        PositionConfig memory config =
            PositionConfig({poolKey: key, tickLower: params.tickLower, tickUpper: params.tickUpper});

        // swap to create fees
        uint256 swapAmount = 0.01e18;
        swap(key, false, int256(swapAmount), ZERO_BYTES);

        uint256 balance0Before = currency0.balanceOfSelf();
        uint256 balance1Before = currency1.balanceOfSelf();
        decreaseLiquidity(tokenId, config, decreaseLiquidityDelta, ZERO_BYTES);
        BalanceDelta delta = getLastDelta();

        uint256 liquidity = lpm.getPositionLiquidity(tokenId);

        assertEq(liquidity, uint256(params.liquidityDelta) - decreaseLiquidityDelta);

        // The change in balance equals the delta returned.
        assertEq(currency0.balanceOfSelf() - balance0Before, uint256(int256(delta.amount0())));
        assertEq(currency1.balanceOfSelf() - balance1Before, uint256(int256(delta.amount1())));
    }

    function test_mintTransferBurn() public {
        PositionConfig memory config = PositionConfig({poolKey: key, tickLower: -600, tickUpper: 600});
        uint256 liquidity = 100e18;
        uint256 tokenId = lpm.nextTokenId();
        mint(config, liquidity, ActionConstants.MSG_SENDER, ZERO_BYTES);
        BalanceDelta mintDelta = getLastDelta();

        // transfer to alice
        IERC721(address(lpm)).transferFrom(address(this), alice, tokenId);

        // alice can burn the position
        bytes memory calls = getBurnEncoded(tokenId, config, ZERO_BYTES);

        uint256 balance0BeforeAlice = currency0.balanceOf(alice);
        uint256 balance1BeforeAlice = currency0.balanceOf(alice);

        vm.prank(alice);
        lpm.modifyLiquidities(calls, _deadline);

        // token was burned and does not exist anymore
        vm.expectRevert();
        IERC721(address(lpm)).ownerOf(tokenId);

        // alice received the principal liquidity
        assertApproxEqAbs(currency0.balanceOf(alice) - balance0BeforeAlice, uint128(-mintDelta.amount0()), 1 wei);
        assertApproxEqAbs(currency1.balanceOf(alice) - balance1BeforeAlice, uint128(-mintDelta.amount1()), 1 wei);
    }

    function test_mintTransferCollect() public {
        PositionConfig memory config = PositionConfig({poolKey: key, tickLower: -600, tickUpper: 600});
        uint256 liquidity = 100e18;
        uint256 tokenId = lpm.nextTokenId();
        mint(config, liquidity, ActionConstants.MSG_SENDER, ZERO_BYTES);

        // donate to generate fee revenue
        uint256 feeRevenue0 = 1e18;
        uint256 feeRevenue1 = 0.1e18;
        donateRouter.donate(key, feeRevenue0, feeRevenue1, ZERO_BYTES);

        // transfer to alice
        IERC721(address(lpm)).transferFrom(address(this), alice, tokenId);

        // alice can collect the fees
        uint256 balance0BeforeAlice = currency0.balanceOf(alice);
        uint256 balance1BeforeAlice = currency1.balanceOf(alice);
        vm.startPrank(alice);
        collect(tokenId, config, ZERO_BYTES);
        BalanceDelta delta = getLastDelta();
        vm.stopPrank();

        // alice received the fee revenue
        assertApproxEqAbs(currency0.balanceOf(alice) - balance0BeforeAlice, feeRevenue0, 1 wei);
        assertApproxEqAbs(currency1.balanceOf(alice) - balance1BeforeAlice, feeRevenue1, 1 wei);
        assertApproxEqAbs(uint128(delta.amount0()), feeRevenue0, 1 wei);
        assertApproxEqAbs(uint128(delta.amount1()), feeRevenue1, 1 wei);
    }

    function test_mintTransferIncrease() public {
        PositionConfig memory config = PositionConfig({poolKey: key, tickLower: -600, tickUpper: 600});
        uint256 liquidity = 100e18;
        uint256 tokenId = lpm.nextTokenId();
        mint(config, liquidity, ActionConstants.MSG_SENDER, ZERO_BYTES);

        // transfer to alice
        IERC721(address(lpm)).transferFrom(address(this), alice, tokenId);

        // alice increases liquidity and is the payer
        uint256 balance0BeforeAlice = currency0.balanceOf(alice);
        uint256 balance1BeforeAlice = currency1.balanceOf(alice);
        vm.startPrank(alice);
        uint256 liquidityToAdd = 10e18;
        increaseLiquidity(tokenId, config, liquidityToAdd, ZERO_BYTES);
        BalanceDelta delta = getLastDelta();
        vm.stopPrank();

        // position liquidity increased
        uint256 newLiq = lpm.getPositionLiquidity(tokenId);
        assertEq(newLiq, liquidity + liquidityToAdd);

        // alice paid the tokens
        (uint256 amount0, uint256 amount1) = LiquidityAmounts.getAmountsForLiquidity(
            SQRT_PRICE_1_1,
            TickMath.getSqrtPriceAtTick(config.tickLower),
            TickMath.getSqrtPriceAtTick(config.tickUpper),
            uint128(liquidityToAdd)
        );
        assertApproxEqAbs(balance0BeforeAlice - currency0.balanceOf(alice), amount0, 1 wei);
        assertApproxEqAbs(balance1BeforeAlice - currency1.balanceOf(alice), amount1, 1 wei);
        assertApproxEqAbs(uint128(-delta.amount0()), amount0, 1 wei);
        assertApproxEqAbs(uint128(-delta.amount1()), amount1, 1 wei);
    }

    function test_mintTransferDecrease() public {
        PositionConfig memory config = PositionConfig({poolKey: key, tickLower: -600, tickUpper: 600});
        uint256 liquidity = 100e18;
        uint256 tokenId = lpm.nextTokenId();
        mint(config, liquidity, ActionConstants.MSG_SENDER, ZERO_BYTES);

        // donate to generate fee revenue
        uint256 feeRevenue0 = 1e18;
        uint256 feeRevenue1 = 0.1e18;
        donateRouter.donate(key, feeRevenue0, feeRevenue1, ZERO_BYTES);

        // transfer to alice
        IERC721(address(lpm)).transferFrom(address(this), alice, tokenId);

        {
            // alice decreases liquidity and is the recipient
            uint256 balance0BeforeAlice = currency0.balanceOf(alice);
            uint256 balance1BeforeAlice = currency1.balanceOf(alice);
            vm.startPrank(alice);
            uint256 liquidityToRemove = 10e18;
            decreaseLiquidity(tokenId, config, liquidityToRemove, ZERO_BYTES);
            BalanceDelta delta = getLastDelta();
            vm.stopPrank();

            {
                // position liquidity decreased
                uint256 newLiq = lpm.getPositionLiquidity(tokenId);
                assertEq(newLiq, liquidity - liquidityToRemove);
            }

            // alice received the principal + fees
            (uint256 amount0, uint256 amount1) = LiquidityAmounts.getAmountsForLiquidity(
                SQRT_PRICE_1_1,
                TickMath.getSqrtPriceAtTick(config.tickLower),
                TickMath.getSqrtPriceAtTick(config.tickUpper),
                uint128(liquidityToRemove)
            );
            assertApproxEqAbs(currency0.balanceOf(alice) - balance0BeforeAlice, amount0 + feeRevenue0, 1 wei);
            assertApproxEqAbs(currency1.balanceOf(alice) - balance1BeforeAlice, amount1 + feeRevenue1, 1 wei);
            assertApproxEqAbs(uint128(delta.amount0()), amount0 + feeRevenue0, 1 wei);
            assertApproxEqAbs(uint128(delta.amount1()), amount1 + feeRevenue1, 1 wei);
        }
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

    // tests a decrease and take in both currencies
    // does not use take pair, so its less optimal
    function test_decrease_take() public {
        PositionConfig memory config = PositionConfig({poolKey: key, tickLower: -120, tickUpper: 120});
        uint256 tokenId = lpm.nextTokenId();
        mint(config, 1e18, ActionConstants.MSG_SENDER, ZERO_BYTES);

        hook.clearDeltas();

        uint256 balanceBefore0 = currency0.balanceOfSelf();
        uint256 balanceBefore1 = currency1.balanceOfSelf();

        Plan memory plan = Planner.init();
        plan.add(
            Actions.DECREASE_LIQUIDITY,
            abi.encode(tokenId, 1e18, MIN_SLIPPAGE_DECREASE, MIN_SLIPPAGE_DECREASE, ZERO_BYTES)
        );
        bytes memory calls = plan.finalizeModifyLiquidityWithTake(config.poolKey, ActionConstants.MSG_SENDER);

        lpm.modifyLiquidities(calls, _deadline);
        BalanceDelta delta = getLastDelta();

        assertEq(currency0.balanceOfSelf(), balanceBefore0 + uint256(int256(delta.amount0())));
        assertEq(currency1.balanceOfSelf(), balanceBefore1 + uint256(int256(delta.amount1())));
    }

    // decrease full range position
    // mint new one sided position in currency1
    // expect to TAKE currency0 and SETTLE currency1
    function test_decrease_increaseCurrency1_take_settle() public {
        PositionConfig memory config = PositionConfig({poolKey: key, tickLower: -120, tickUpper: 120});
        uint256 tokenId = lpm.nextTokenId();
        mint(config, 1e18, ActionConstants.MSG_SENDER, ZERO_BYTES);

        hook.clearDeltas();

        uint256 balanceBefore0 = currency0.balanceOfSelf();
        uint256 balanceBefore1 = currency1.balanceOfSelf();

        uint256 tokenIdMint = lpm.nextTokenId();

        // one-sided liq in currency1
        PositionConfig memory configMint = PositionConfig({poolKey: key, tickLower: -120, tickUpper: 0});

        Plan memory plan = Planner.init();
        plan.add(
            Actions.DECREASE_LIQUIDITY,
            abi.encode(tokenId, 1e18, MIN_SLIPPAGE_DECREASE, MIN_SLIPPAGE_DECREASE, ZERO_BYTES)
        );
        plan.add(
            Actions.MINT_POSITION,
            abi.encode(
                configMint.poolKey,
                configMint.tickLower,
                configMint.tickUpper,
                1e18,
                MAX_SLIPPAGE_INCREASE,
                MAX_SLIPPAGE_INCREASE,
                ActionConstants.MSG_SENDER,
                ZERO_BYTES
            )
        );
        plan.add(Actions.TAKE, abi.encode(key.currency0, ActionConstants.MSG_SENDER, ActionConstants.OPEN_DELTA));
        plan.add(Actions.SETTLE, abi.encode(key.currency1, ActionConstants.OPEN_DELTA, true));
        bytes memory calls = plan.finalizeModifyLiquidityWithTake(config.poolKey, ActionConstants.MSG_SENDER);

        lpm.modifyLiquidities(calls, _deadline);
        BalanceDelta deltaDecrease = hook.deltas(0);
        BalanceDelta deltaMint = hook.deltas(1);

        assertEq(deltaMint.amount0(), 0); // there is no currency0 in the new position
        assertEq(currency0.balanceOfSelf(), balanceBefore0 + uint256(int256(deltaDecrease.amount0())));
        assertEq(
            currency1.balanceOfSelf(), balanceBefore1 - uint256(-int256(deltaDecrease.amount1() + deltaMint.amount1()))
        );
        assertEq(IERC721(address(lpm)).ownerOf(tokenIdMint), address(this));
        assertLt(currency1.balanceOfSelf(), balanceBefore1); // currency1 was owed
        assertLt(uint256(int256(deltaDecrease.amount1())), uint256(int256(-deltaMint.amount1()))); // amount1 in the second position was greater than amount1 in the first position
    }

    function test_mint_slippageRevert() public {}
}
