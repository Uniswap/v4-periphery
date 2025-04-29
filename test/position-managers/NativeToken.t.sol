// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FixedPointMathLib} from "solmate/src/utils/FixedPointMathLib.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import {Position} from "@uniswap/v4-core/src/libraries/Position.sol";

import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {IERC721} from "forge-std/interfaces/IERC721.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";

import {IPositionManager} from "../../src/interfaces/IPositionManager.sol";
import {Actions} from "../../src/libraries/Actions.sol";
import {ActionConstants} from "../../src/libraries/ActionConstants.sol";

import {MockSubscriber} from "../mocks/MockSubscriber.sol";
import {LiquidityFuzzers} from "../shared/fuzz/LiquidityFuzzers.sol";
import {PosmTestSetup} from "../shared/PosmTestSetup.sol";
import {Planner, Plan} from "../shared/Planner.sol";
import {PositionConfig} from "../shared/PositionConfig.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

contract PositionManagerTest is Test, PosmTestSetup, LiquidityFuzzers {
    using FixedPointMathLib for uint256;
    using StateLibrary for IPoolManager;
    using SafeCast for *;

    PoolId poolId;

    MockSubscriber sub;

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();

        // This is needed to receive return deltas from modifyLiquidity calls.
        deployPosmHookSavesDelta();

        currency0 = CurrencyLibrary.ADDRESS_ZERO;
        (nativeKey, poolId) = initPool(currency0, currency1, IHooks(hook), 3000, SQRT_PRICE_1_1);

        deployPosm(manager);
        // currency0 is the native token so only execute approvals for currency1.
        approvePosmCurrency(currency1);

        sub = new MockSubscriber(lpm);

        vm.deal(address(this), type(uint256).max);
    }

    function test_fuzz_mint_native(ModifyLiquidityParams memory params) public {
        params = createFuzzyLiquidityParams(nativeKey, params, SQRT_PRICE_1_1);
        vm.assume(params.tickLower < 0 && 0 < params.tickUpper); // two-sided liquidity

        uint256 liquidityToAdd =
            params.liquidityDelta < 0 ? uint256(-params.liquidityDelta) : uint256(params.liquidityDelta);
        PositionConfig memory config =
            PositionConfig({poolKey: nativeKey, tickLower: params.tickLower, tickUpper: params.tickUpper});

        uint256 balance0Before = currency0.balanceOfSelf();
        uint256 balance1Before = currency1.balanceOfSelf();

        uint256 tokenId = lpm.nextTokenId();
        bytes memory calls = getMintEncoded(config, liquidityToAdd, ActionConstants.MSG_SENDER, ZERO_BYTES);

        (uint256 amount0,) = LiquidityAmounts.getAmountsForLiquidity(
            SQRT_PRICE_1_1,
            TickMath.getSqrtPriceAtTick(params.tickLower),
            TickMath.getSqrtPriceAtTick(params.tickUpper),
            liquidityToAdd.toUint128()
        );
        // add extra wei because modifyLiquidities may be rounding up, LiquidityAmounts is imprecise?
        lpm.modifyLiquidities{value: amount0 + 1}(calls, _deadline);
        BalanceDelta delta = getLastDelta();

        uint256 liquidity = lpm.getPositionLiquidity(tokenId);

        assertEq(liquidity, uint256(params.liquidityDelta));
        assertEq(balance0Before - currency0.balanceOfSelf(), uint256(int256(-delta.amount0())), "incorrect amount0");
        assertEq(balance1Before - currency1.balanceOfSelf(), uint256(int256(-delta.amount1())), "incorrect amount1");
    }

    // minting with excess native tokens are returned to caller
    function test_fuzz_mint_native_excess_withClose(ModifyLiquidityParams memory params) public {
        params = createFuzzyLiquidityParams(nativeKey, params, SQRT_PRICE_1_1);
        vm.assume(params.tickLower < 0 && 0 < params.tickUpper); // two-sided liquidity

        uint256 liquidityToAdd =
            params.liquidityDelta < 0 ? uint256(-params.liquidityDelta) : uint256(params.liquidityDelta);
        PositionConfig memory config =
            PositionConfig({poolKey: nativeKey, tickLower: params.tickLower, tickUpper: params.tickUpper});

        uint256 balance0Before = currency0.balanceOfSelf();
        uint256 balance1Before = currency1.balanceOfSelf();

        uint256 tokenId = lpm.nextTokenId();

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
                ActionConstants.MSG_SENDER,
                ZERO_BYTES
            )
        );
        planner.add(Actions.CLOSE_CURRENCY, abi.encode(nativeKey.currency0));
        planner.add(Actions.CLOSE_CURRENCY, abi.encode(nativeKey.currency1));
        // sweep the excess eth
        planner.add(Actions.SWEEP, abi.encode(currency0, ActionConstants.MSG_SENDER));

        bytes memory calls = planner.encode();

        (uint256 amount0,) = LiquidityAmounts.getAmountsForLiquidity(
            SQRT_PRICE_1_1,
            TickMath.getSqrtPriceAtTick(params.tickLower),
            TickMath.getSqrtPriceAtTick(params.tickUpper),
            liquidityToAdd.toUint128()
        );

        // Mint with excess native tokens
        lpm.modifyLiquidities{value: amount0 * 2 + 1}(calls, _deadline);
        BalanceDelta delta = getLastDelta();

        uint256 liquidity = lpm.getPositionLiquidity(tokenId);
        assertEq(liquidity, uint256(params.liquidityDelta));

        // only paid the delta amount, with excess tokens returned to caller
        assertEq(balance0Before - currency0.balanceOfSelf(), uint256(int256(-delta.amount0())));
        assertEq(balance0Before - currency0.balanceOfSelf(), amount0 + 1); // TODO: off by one??
        assertEq(balance1Before - currency1.balanceOfSelf(), uint256(int256(-delta.amount1())));
    }

    function test_fuzz_mint_native_excess_withSettlePair(ModifyLiquidityParams memory params) public {
        params = createFuzzyLiquidityParams(nativeKey, params, SQRT_PRICE_1_1);
        vm.assume(params.tickLower < 0 && 0 < params.tickUpper); // two-sided liquidity

        uint256 liquidityToAdd =
            params.liquidityDelta < 0 ? uint256(-params.liquidityDelta) : uint256(params.liquidityDelta);
        PositionConfig memory config =
            PositionConfig({poolKey: nativeKey, tickLower: params.tickLower, tickUpper: params.tickUpper});

        uint256 balance0Before = currency0.balanceOfSelf();
        uint256 balance1Before = currency1.balanceOfSelf();

        uint256 tokenId = lpm.nextTokenId();

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
        planner.add(Actions.SETTLE_PAIR, abi.encode(nativeKey.currency0, nativeKey.currency1));
        // sweep the excess eth
        planner.add(Actions.SWEEP, abi.encode(currency0, address(this)));

        bytes memory calls = planner.encode();

        (uint256 amount0,) = LiquidityAmounts.getAmountsForLiquidity(
            SQRT_PRICE_1_1,
            TickMath.getSqrtPriceAtTick(params.tickLower),
            TickMath.getSqrtPriceAtTick(params.tickUpper),
            liquidityToAdd.toUint128()
        );

        // Mint with excess native tokens
        lpm.modifyLiquidities{value: amount0 * 2 + 1}(calls, _deadline);
        BalanceDelta delta = getLastDelta();

        uint256 liquidity = lpm.getPositionLiquidity(tokenId);
        assertEq(liquidity, uint256(params.liquidityDelta));

        // only paid the delta amount, with excess tokens returned to caller
        assertEq(balance0Before - currency0.balanceOfSelf(), uint256(int256(-delta.amount0())));
        assertEq(balance0Before - currency0.balanceOfSelf(), amount0 + 1); // TODO: off by one??
        assertEq(balance1Before - currency1.balanceOfSelf(), uint256(int256(-delta.amount1())));
    }

    function test_fuzz_burn_native_emptyPosition_withClose(ModifyLiquidityParams memory params) public {
        uint256 balance0Start = address(this).balance;
        uint256 balance1Start = currency1.balanceOfSelf();

        params = createFuzzyLiquidityParams(nativeKey, params, SQRT_PRICE_1_1);
        vm.assume(params.tickLower < 0 && 0 < params.tickUpper); // two-sided liquidity

        uint256 liquidityToAdd =
            params.liquidityDelta < 0 ? uint256(-params.liquidityDelta) : uint256(params.liquidityDelta);
        PositionConfig memory config =
            PositionConfig({poolKey: nativeKey, tickLower: params.tickLower, tickUpper: params.tickUpper});

        uint256 tokenId = lpm.nextTokenId();
        mintWithNative(SQRT_PRICE_1_1, config, liquidityToAdd, ActionConstants.MSG_SENDER, ZERO_BYTES);

        uint256 liquidity = lpm.getPositionLiquidity(tokenId);
        assertEq(liquidity, uint256(params.liquidityDelta));

        // burn liquidity
        uint256 balance0BeforeBurn = currency0.balanceOfSelf();
        uint256 balance1BeforeBurn = currency1.balanceOfSelf();

        decreaseLiquidity(tokenId, config, liquidity, ZERO_BYTES);
        BalanceDelta deltaDecrease = getLastDelta();

        uint256 numDeltas = hook.numberDeltasReturned();
        burn(tokenId, config, ZERO_BYTES);
        // No decrease/modifyLiq call will actually happen on the call to burn so the deltas array will be the same length.
        assertEq(numDeltas, hook.numberDeltasReturned());

        liquidity = lpm.getPositionLiquidity(tokenId);
        assertEq(liquidity, 0);

        // TODO: slightly off by 1 bip (0.0001%)
        assertApproxEqRel(
            currency0.balanceOfSelf(), balance0BeforeBurn + uint256(uint128(deltaDecrease.amount0())), 0.0001e18
        );
        assertApproxEqRel(
            currency1.balanceOfSelf(), balance1BeforeBurn + uint256(uint128(deltaDecrease.amount1())), 0.0001e18
        );

        // OZ 721 will revert if the token does not exist
        vm.expectRevert();
        IERC721(address(lpm)).ownerOf(1);

        // no tokens were lost, TODO: fuzzer showing off by 1 sometimes
        assertApproxEqAbs(currency0.balanceOfSelf(), balance0Start, 1 wei);
        assertApproxEqAbs(address(this).balance, balance0Start, 1 wei);
        assertApproxEqAbs(currency1.balanceOfSelf(), balance1Start, 1 wei);
    }

    function test_fuzz_burn_native_emptyPosition_withTakePair(ModifyLiquidityParams memory params) public {
        uint256 balance0Start = address(this).balance;
        uint256 balance1Start = currency1.balanceOfSelf();

        params = createFuzzyLiquidityParams(nativeKey, params, SQRT_PRICE_1_1);
        vm.assume(params.tickLower < 0 && 0 < params.tickUpper); // two-sided liquidity

        uint256 liquidityToAdd =
            params.liquidityDelta < 0 ? uint256(-params.liquidityDelta) : uint256(params.liquidityDelta);
        PositionConfig memory config =
            PositionConfig({poolKey: nativeKey, tickLower: params.tickLower, tickUpper: params.tickUpper});

        uint256 tokenId = lpm.nextTokenId();
        mintWithNative(SQRT_PRICE_1_1, config, liquidityToAdd, ActionConstants.MSG_SENDER, ZERO_BYTES);

        uint256 liquidity = lpm.getPositionLiquidity(tokenId);
        assertEq(liquidity, uint256(params.liquidityDelta));

        // burn liquidity
        uint256 balance0BeforeBurn = currency0.balanceOfSelf();
        uint256 balance1BeforeBurn = currency1.balanceOfSelf();

        decreaseLiquidity(tokenId, config, liquidity, ZERO_BYTES);
        BalanceDelta deltaDecrease = getLastDelta();

        uint256 numDeltas = hook.numberDeltasReturned();
        Plan memory planner = Planner.init();
        planner.add(
            Actions.BURN_POSITION, abi.encode(tokenId, MIN_SLIPPAGE_DECREASE, MIN_SLIPPAGE_DECREASE, ZERO_BYTES)
        );
        bytes memory calls = planner.finalizeModifyLiquidityWithTakePair(config.poolKey, address(this));
        lpm.modifyLiquidities(calls, _deadline);
        // No decrease/modifyLiq call will actually happen on the call to burn so the deltas array will be the same length.
        assertEq(numDeltas, hook.numberDeltasReturned());

        liquidity = lpm.getPositionLiquidity(tokenId);
        assertEq(liquidity, 0);

        // TODO: slightly off by 1 bip (0.0001%)
        assertApproxEqRel(
            currency0.balanceOfSelf(), balance0BeforeBurn + uint256(uint128(deltaDecrease.amount0())), 0.0001e18
        );
        assertApproxEqRel(
            currency1.balanceOfSelf(), balance1BeforeBurn + uint256(uint128(deltaDecrease.amount1())), 0.0001e18
        );

        // OZ 721 will revert if the token does not exist
        vm.expectRevert();
        IERC721(address(lpm)).ownerOf(1);

        // no tokens were lost, TODO: fuzzer showing off by 1 sometimes
        assertApproxEqAbs(currency0.balanceOfSelf(), balance0Start, 1 wei);
        assertApproxEqAbs(address(this).balance, balance0Start, 1 wei);
        assertApproxEqAbs(currency1.balanceOfSelf(), balance1Start, 1 wei);
    }

    function test_fuzz_burn_native_nonEmptyPosition_withClose(ModifyLiquidityParams memory params) public {
        uint256 balance0Start = address(this).balance;
        uint256 balance1Start = currency1.balanceOfSelf();

        params = createFuzzyLiquidityParams(nativeKey, params, SQRT_PRICE_1_1);
        vm.assume(params.tickLower < 0 && 0 < params.tickUpper); // two-sided liquidity

        uint256 liquidityToAdd =
            params.liquidityDelta < 0 ? uint256(-params.liquidityDelta) : uint256(params.liquidityDelta);
        PositionConfig memory config =
            PositionConfig({poolKey: nativeKey, tickLower: params.tickLower, tickUpper: params.tickUpper});

        uint256 tokenId = lpm.nextTokenId();
        mintWithNative(SQRT_PRICE_1_1, config, liquidityToAdd, ActionConstants.MSG_SENDER, ZERO_BYTES);

        uint256 liquidity = lpm.getPositionLiquidity(tokenId);
        assertEq(liquidity, uint256(params.liquidityDelta));

        // burn liquidity
        uint256 balance0BeforeBurn = currency0.balanceOfSelf();
        uint256 balance1BeforeBurn = currency1.balanceOfSelf();

        burn(tokenId, config, ZERO_BYTES);
        BalanceDelta deltaBurn = getLastDelta();

        liquidity = lpm.getPositionLiquidity(tokenId);
        assertEq(liquidity, 0);

        // TODO: slightly off by 1 bip (0.0001%)
        assertApproxEqRel(
            currency0.balanceOfSelf(), balance0BeforeBurn + uint256(uint128(deltaBurn.amount0())), 0.0001e18
        );
        assertApproxEqRel(
            currency1.balanceOfSelf(), balance1BeforeBurn + uint256(uint128(deltaBurn.amount1())), 0.0001e18
        );

        // OZ 721 will revert if the token does not exist
        vm.expectRevert();
        IERC721(address(lpm)).ownerOf(1);

        // no tokens were lost, TODO: fuzzer showing off by 1 sometimes
        assertApproxEqAbs(currency0.balanceOfSelf(), balance0Start, 1 wei);
        assertApproxEqAbs(address(this).balance, balance0Start, 1 wei);
        assertApproxEqAbs(currency1.balanceOfSelf(), balance1Start, 1 wei);
    }

    function test_fuzz_burn_native_nonEmptyPosition_withTakePair(ModifyLiquidityParams memory params) public {
        uint256 balance0Start = address(this).balance;
        uint256 balance1Start = currency1.balanceOfSelf();

        params = createFuzzyLiquidityParams(nativeKey, params, SQRT_PRICE_1_1);
        vm.assume(params.tickLower < 0 && 0 < params.tickUpper); // two-sided liquidity

        uint256 liquidityToAdd =
            params.liquidityDelta < 0 ? uint256(-params.liquidityDelta) : uint256(params.liquidityDelta);
        PositionConfig memory config =
            PositionConfig({poolKey: nativeKey, tickLower: params.tickLower, tickUpper: params.tickUpper});

        uint256 tokenId = lpm.nextTokenId();
        mintWithNative(SQRT_PRICE_1_1, config, liquidityToAdd, ActionConstants.MSG_SENDER, ZERO_BYTES);

        uint256 liquidity = lpm.getPositionLiquidity(tokenId);
        assertEq(liquidity, uint256(params.liquidityDelta));

        // burn liquidity
        uint256 balance0BeforeBurn = currency0.balanceOfSelf();
        uint256 balance1BeforeBurn = currency1.balanceOfSelf();

        Plan memory planner = Planner.init();
        planner.add(
            Actions.BURN_POSITION, abi.encode(tokenId, MIN_SLIPPAGE_DECREASE, MIN_SLIPPAGE_DECREASE, ZERO_BYTES)
        );
        bytes memory calls = planner.finalizeModifyLiquidityWithTakePair(config.poolKey, address(this));
        lpm.modifyLiquidities(calls, _deadline);
        BalanceDelta deltaBurn = getLastDelta();

        liquidity = lpm.getPositionLiquidity(tokenId);
        assertEq(liquidity, 0);

        // TODO: slightly off by 1 bip (0.0001%)
        assertApproxEqRel(
            currency0.balanceOfSelf(), balance0BeforeBurn + uint256(uint128(deltaBurn.amount0())), 0.0001e18
        );
        assertApproxEqRel(
            currency1.balanceOfSelf(), balance1BeforeBurn + uint256(uint128(deltaBurn.amount1())), 0.0001e18
        );

        // OZ 721 will revert if the token does not exist
        vm.expectRevert();
        IERC721(address(lpm)).ownerOf(1);

        // no tokens were lost, TODO: fuzzer showing off by 1 sometimes
        assertApproxEqAbs(currency0.balanceOfSelf(), balance0Start, 1 wei);
        assertApproxEqAbs(address(this).balance, balance0Start, 1 wei);
        assertApproxEqAbs(currency1.balanceOfSelf(), balance1Start, 1 wei);
    }

    function test_fuzz_increaseLiquidity_native(ModifyLiquidityParams memory params) public {
        // fuzz for the range
        params = createFuzzyLiquidityParams(nativeKey, params, SQRT_PRICE_1_1);
        vm.assume(params.tickLower < -60 && 60 < params.tickUpper); // two-sided liquidity

        // TODO: figure out if we can fuzz the increase liquidity delta. we're annoyingly getting TickLiquidityOverflow
        uint256 liquidityToAdd = 1e18;
        PositionConfig memory config =
            PositionConfig({poolKey: nativeKey, tickLower: params.tickLower, tickUpper: params.tickUpper});

        // mint the position with native token liquidity
        uint256 tokenId = lpm.nextTokenId();
        mintWithNative(SQRT_PRICE_1_1, config, liquidityToAdd, ActionConstants.MSG_SENDER, ZERO_BYTES);

        uint256 balance0Before = address(this).balance;
        uint256 balance1Before = currency1.balanceOfSelf();

        // calculate how much native token is required for the liquidity increase (doubling the liquidity)
        (uint256 amount0,) = LiquidityAmounts.getAmountsForLiquidity(
            SQRT_PRICE_1_1,
            TickMath.getSqrtPriceAtTick(params.tickLower),
            TickMath.getSqrtPriceAtTick(params.tickUpper),
            uint128(liquidityToAdd)
        );

        bytes memory calls = getIncreaseEncoded(tokenId, config, liquidityToAdd, ZERO_BYTES); // double the liquidity
        lpm.modifyLiquidities{value: amount0 + 1 wei}(calls, _deadline); // TODO: off by one wei
        BalanceDelta delta = getLastDelta();

        // verify position liquidity increased
        uint256 liquidity = lpm.getPositionLiquidity(tokenId);
        assertEq(liquidity, liquidityToAdd + liquidityToAdd); // liquidity was doubled

        // verify native token balances changed as expected
        assertEq(balance0Before - currency0.balanceOfSelf(), amount0 + 1 wei);
        assertEq(balance0Before - currency0.balanceOfSelf(), uint256(int256(-delta.amount0())));
        assertEq(balance1Before - currency1.balanceOfSelf(), uint256(int256(-delta.amount1())));
    }

    // overpaying native tokens on increase liquidity is returned to caller
    function test_fuzz_increaseLiquidity_native_excess_withClose(ModifyLiquidityParams memory params) public {
        // fuzz for the range
        params = createFuzzyLiquidityParams(nativeKey, params, SQRT_PRICE_1_1);
        vm.assume(params.tickLower < 0 && 0 < params.tickUpper); // two-sided liquidity

        // TODO: figure out if we can fuzz the increase liquidity delta. we're annoyingly getting TickLiquidityOverflow
        uint256 liquidityToAdd = 1e18;
        PositionConfig memory config =
            PositionConfig({poolKey: nativeKey, tickLower: params.tickLower, tickUpper: params.tickUpper});

        // mint the position with native token liquidity
        uint256 tokenId = lpm.nextTokenId();
        mintWithNative(SQRT_PRICE_1_1, config, liquidityToAdd, ActionConstants.MSG_SENDER, ZERO_BYTES);

        uint256 balance0Before = address(this).balance;
        uint256 balance1Before = currency1.balanceOfSelf();

        // calculate how much native token is required for the liquidity increase (doubling the liquidity)
        (uint256 amount0,) = LiquidityAmounts.getAmountsForLiquidity(
            SQRT_PRICE_1_1,
            TickMath.getSqrtPriceAtTick(params.tickLower),
            TickMath.getSqrtPriceAtTick(params.tickUpper),
            uint128(liquidityToAdd)
        );

        Plan memory planner = Planner.init();
        planner.add(
            Actions.INCREASE_LIQUIDITY,
            abi.encode(tokenId, liquidityToAdd, MAX_SLIPPAGE_INCREASE, MAX_SLIPPAGE_INCREASE, ZERO_BYTES)
        );
        planner.add(Actions.CLOSE_CURRENCY, abi.encode(nativeKey.currency0));
        planner.add(Actions.CLOSE_CURRENCY, abi.encode(nativeKey.currency1));
        // sweep the excess eth
        planner.add(Actions.SWEEP, abi.encode(currency0, ActionConstants.MSG_SENDER));
        bytes memory calls = planner.encode();

        lpm.modifyLiquidities{value: amount0 * 2}(calls, _deadline); // overpay on increase liquidity
        BalanceDelta delta = getLastDelta();

        // verify position liquidity increased
        uint256 liquidity = lpm.getPositionLiquidity(tokenId);
        assertEq(liquidity, liquidityToAdd + liquidityToAdd); // liquidity was doubled

        // verify native token balances changed as expected, with overpaid tokens returned
        assertEq(balance0Before - currency0.balanceOfSelf(), amount0 + 1 wei);
        assertEq(balance0Before - currency0.balanceOfSelf(), uint256(int256(-delta.amount0())));
        assertEq(balance1Before - currency1.balanceOfSelf(), uint256(int256(-delta.amount1())));
    }

    function test_fuzz_increaseLiquidity_native_excess_withSettlePair(ModifyLiquidityParams memory params) public {
        // fuzz for the range
        params = createFuzzyLiquidityParams(nativeKey, params, SQRT_PRICE_1_1);
        vm.assume(params.tickLower < 0 && 0 < params.tickUpper); // two-sided liquidity

        // TODO: figure out if we can fuzz the increase liquidity delta. we're annoyingly getting TickLiquidityOverflow
        uint256 liquidityToAdd = 1e18;
        PositionConfig memory config =
            PositionConfig({poolKey: nativeKey, tickLower: params.tickLower, tickUpper: params.tickUpper});

        // mint the position with native token liquidity
        uint256 tokenId = lpm.nextTokenId();
        mintWithNative(SQRT_PRICE_1_1, config, liquidityToAdd, address(this), ZERO_BYTES);

        uint256 balance0Before = address(this).balance;
        uint256 balance1Before = currency1.balanceOfSelf();

        // calculate how much native token is required for the liquidity increase (doubling the liquidity)
        (uint256 amount0,) = LiquidityAmounts.getAmountsForLiquidity(
            SQRT_PRICE_1_1,
            TickMath.getSqrtPriceAtTick(params.tickLower),
            TickMath.getSqrtPriceAtTick(params.tickUpper),
            uint128(liquidityToAdd)
        );

        Plan memory planner = Planner.init();
        planner.add(
            Actions.INCREASE_LIQUIDITY,
            abi.encode(tokenId, liquidityToAdd, MAX_SLIPPAGE_INCREASE, MAX_SLIPPAGE_INCREASE, ZERO_BYTES)
        );
        planner.add(Actions.SETTLE_PAIR, abi.encode(nativeKey.currency0, nativeKey.currency1));
        // sweep the excess eth
        planner.add(Actions.SWEEP, abi.encode(currency0, address(this)));
        bytes memory calls = planner.encode();

        lpm.modifyLiquidities{value: amount0 * 2}(calls, _deadline); // overpay on increase liquidity
        BalanceDelta delta = getLastDelta();

        // verify position liquidity increased
        uint256 liquidity = lpm.getPositionLiquidity(tokenId);
        assertEq(liquidity, liquidityToAdd + liquidityToAdd); // liquidity was doubled

        // verify native token balances changed as expected, with overpaid tokens returned
        assertEq(balance0Before - currency0.balanceOfSelf(), amount0 + 1 wei);
        assertEq(balance0Before - currency0.balanceOfSelf(), uint256(int256(-delta.amount0())));
        assertEq(balance1Before - currency1.balanceOfSelf(), uint256(int256(-delta.amount1())));
    }

    function test_fuzz_decreaseLiquidity_native_withClose(
        ModifyLiquidityParams memory params,
        uint256 decreaseLiquidityDelta
    ) public {
        params = createFuzzyLiquidityParams(nativeKey, params, SQRT_PRICE_1_1);
        vm.assume(params.tickLower < 0 && 0 < params.tickUpper); // two-sided liquidity
        decreaseLiquidityDelta = bound(decreaseLiquidityDelta, 1, uint256(params.liquidityDelta));

        PositionConfig memory config =
            PositionConfig({poolKey: nativeKey, tickLower: params.tickLower, tickUpper: params.tickUpper});

        // mint the position with native token liquidity
        uint256 tokenId = lpm.nextTokenId();
        mintWithNative(SQRT_PRICE_1_1, config, uint256(params.liquidityDelta), ActionConstants.MSG_SENDER, ZERO_BYTES);

        uint256 balance0Before = address(this).balance;
        uint256 balance1Before = currency1.balanceOfSelf();

        // decrease liquidity and receive native tokens
        (uint256 amount0,) = LiquidityAmounts.getAmountsForLiquidity(
            SQRT_PRICE_1_1,
            TickMath.getSqrtPriceAtTick(params.tickLower),
            TickMath.getSqrtPriceAtTick(params.tickUpper),
            uint128(decreaseLiquidityDelta)
        );
        decreaseLiquidity(tokenId, config, decreaseLiquidityDelta, ZERO_BYTES);
        BalanceDelta delta = getLastDelta();

        uint256 liquidity = lpm.getPositionLiquidity(tokenId);
        assertEq(liquidity, uint256(params.liquidityDelta) - decreaseLiquidityDelta);

        // verify native token balances changed as expected
        assertApproxEqAbs(currency0.balanceOfSelf() - balance0Before, amount0, 1 wei);
        assertEq(currency0.balanceOfSelf() - balance0Before, uint128(delta.amount0()));
        assertEq(currency1.balanceOfSelf() - balance1Before, uint128(delta.amount1()));
    }

    function test_fuzz_decreaseLiquidity_native_withTakePair(
        ModifyLiquidityParams memory params,
        uint256 decreaseLiquidityDelta
    ) public {
        params = createFuzzyLiquidityParams(nativeKey, params, SQRT_PRICE_1_1);
        vm.assume(params.tickLower < 0 && 0 < params.tickUpper); // two-sided liquidity
        decreaseLiquidityDelta = bound(decreaseLiquidityDelta, 1, uint256(params.liquidityDelta));

        PositionConfig memory config =
            PositionConfig({poolKey: nativeKey, tickLower: params.tickLower, tickUpper: params.tickUpper});

        // mint the position with native token liquidity
        uint256 tokenId = lpm.nextTokenId();
        mintWithNative(SQRT_PRICE_1_1, config, uint256(params.liquidityDelta), ActionConstants.MSG_SENDER, ZERO_BYTES);

        uint256 balance0Before = address(this).balance;
        uint256 balance1Before = currency1.balanceOfSelf();

        // decrease liquidity and receive native tokens
        (uint256 amount0,) = LiquidityAmounts.getAmountsForLiquidity(
            SQRT_PRICE_1_1,
            TickMath.getSqrtPriceAtTick(params.tickLower),
            TickMath.getSqrtPriceAtTick(params.tickUpper),
            uint128(decreaseLiquidityDelta)
        );
        Plan memory planner = Planner.init();
        planner.add(
            Actions.DECREASE_LIQUIDITY,
            abi.encode(tokenId, decreaseLiquidityDelta, MIN_SLIPPAGE_DECREASE, MIN_SLIPPAGE_DECREASE, ZERO_BYTES)
        );
        bytes memory calls = planner.finalizeModifyLiquidityWithTakePair(config.poolKey, address(this));
        lpm.modifyLiquidities(calls, _deadline);
        BalanceDelta delta = getLastDelta();

        uint256 liquidity = lpm.getPositionLiquidity(tokenId);
        assertEq(liquidity, uint256(params.liquidityDelta) - decreaseLiquidityDelta);

        // verify native token balances changed as expected
        assertApproxEqAbs(currency0.balanceOfSelf() - balance0Before, amount0, 1 wei);
        assertEq(currency0.balanceOfSelf() - balance0Before, uint128(delta.amount0()));
        assertEq(currency1.balanceOfSelf() - balance1Before, uint128(delta.amount1()));
    }

    function test_fuzz_collect_native_withClose(ModifyLiquidityParams memory params) public {
        params = createFuzzyLiquidityParams(nativeKey, params, SQRT_PRICE_1_1);
        vm.assume(params.tickLower < 0 && 0 < params.tickUpper); // two-sided liquidity

        PositionConfig memory config =
            PositionConfig({poolKey: nativeKey, tickLower: params.tickLower, tickUpper: params.tickUpper});

        // mint the position with native token liquidity
        uint256 tokenId = lpm.nextTokenId();
        mintWithNative(SQRT_PRICE_1_1, config, uint256(params.liquidityDelta), ActionConstants.MSG_SENDER, ZERO_BYTES);

        // donate to generate fee revenue
        uint256 feeRevenue0 = 1e18;
        uint256 feeRevenue1 = 0.1e18;
        donateRouter.donate{value: 1e18}(nativeKey, feeRevenue0, feeRevenue1, ZERO_BYTES);

        uint256 balance0Before = address(this).balance;
        uint256 balance1Before = currency1.balanceOfSelf();
        collect(tokenId, config, ZERO_BYTES);
        BalanceDelta delta = getLastDelta();

        assertApproxEqAbs(currency0.balanceOfSelf() - balance0Before, feeRevenue0, 1 wei); // TODO: fuzzer off by 1 wei
        assertEq(currency0.balanceOfSelf() - balance0Before, uint128(delta.amount0()));
        assertEq(currency1.balanceOfSelf() - balance1Before, uint128(delta.amount1()));
    }

    function test_fuzz_collect_native_withTakePair(ModifyLiquidityParams memory params) public {
        params = createFuzzyLiquidityParams(nativeKey, params, SQRT_PRICE_1_1);
        vm.assume(params.tickLower < 0 && 0 < params.tickUpper); // two-sided liquidity

        PositionConfig memory config =
            PositionConfig({poolKey: nativeKey, tickLower: params.tickLower, tickUpper: params.tickUpper});

        // mint the position with native token liquidity
        uint256 tokenId = lpm.nextTokenId();
        mintWithNative(SQRT_PRICE_1_1, config, uint256(params.liquidityDelta), ActionConstants.MSG_SENDER, ZERO_BYTES);

        // donate to generate fee revenue
        uint256 feeRevenue0 = 1e18;
        uint256 feeRevenue1 = 0.1e18;
        donateRouter.donate{value: 1e18}(nativeKey, feeRevenue0, feeRevenue1, ZERO_BYTES);

        uint256 balance0Before = address(this).balance;
        uint256 balance1Before = currency1.balanceOfSelf();
        Plan memory planner = Planner.init();
        planner.add(
            Actions.DECREASE_LIQUIDITY, abi.encode(tokenId, 0, MIN_SLIPPAGE_DECREASE, MIN_SLIPPAGE_DECREASE, ZERO_BYTES)
        );
        bytes memory calls = planner.finalizeModifyLiquidityWithTakePair(config.poolKey, address(this));
        lpm.modifyLiquidities(calls, _deadline);
        BalanceDelta delta = getLastDelta();

        assertApproxEqAbs(currency0.balanceOfSelf() - balance0Before, feeRevenue0, 1 wei); // TODO: fuzzer off by 1 wei
        assertEq(currency0.balanceOfSelf() - balance0Before, uint128(delta.amount0()));
        assertEq(currency1.balanceOfSelf() - balance1Before, uint128(delta.amount1()));
    }

    function test_fuzz_collect_native_withTakePair_addressRecipient(ModifyLiquidityParams memory params) public {
        params = createFuzzyLiquidityParams(nativeKey, params, SQRT_PRICE_1_1);
        vm.assume(params.tickLower < 0 && 0 < params.tickUpper); // two-sided liquidity

        PositionConfig memory config =
            PositionConfig({poolKey: nativeKey, tickLower: params.tickLower, tickUpper: params.tickUpper});

        // mint the position with native token liquidity
        uint256 tokenId = lpm.nextTokenId();
        mintWithNative(SQRT_PRICE_1_1, config, uint256(params.liquidityDelta), ActionConstants.MSG_SENDER, ZERO_BYTES);

        // donate to generate fee revenue
        uint256 feeRevenue0 = 1e18;
        uint256 feeRevenue1 = 0.1e18;
        donateRouter.donate{value: 1e18}(nativeKey, feeRevenue0, feeRevenue1, ZERO_BYTES);

        uint256 balance0Before = address(this).balance;
        uint256 balance1Before = currency1.balanceOfSelf();

        Plan memory planner = Planner.init();
        planner.add(
            Actions.DECREASE_LIQUIDITY, abi.encode(tokenId, 0, MIN_SLIPPAGE_DECREASE, MIN_SLIPPAGE_DECREASE, ZERO_BYTES)
        );

        address alice = address(0xABCD);

        uint256 aliceBalance0Before = currency0.balanceOf(alice);
        uint256 aliceBalance1Before = currency1.balanceOf(alice);

        bytes memory calls = planner.finalizeModifyLiquidityWithTakePair(config.poolKey, alice);
        lpm.modifyLiquidities(calls, _deadline);
        BalanceDelta delta = getLastDelta();

        assertEq(currency0.balanceOfSelf() - balance0Before, 0);
        assertEq(currency1.balanceOfSelf() - balance1Before, 0);

        assertApproxEqAbs(currency0.balanceOf(alice) - aliceBalance0Before, feeRevenue0, 1 wei); // TODO: fuzzer off by 1 wei
        assertEq(currency0.balanceOf(alice) - aliceBalance0Before, uint128(delta.amount0()));
        assertEq(currency1.balanceOf(alice) - aliceBalance1Before, uint128(delta.amount1()));
    }

    function test_fuzz_collect_native_withTakePair_msgSenderRecipient(ModifyLiquidityParams memory params) public {
        params = createFuzzyLiquidityParams(nativeKey, params, SQRT_PRICE_1_1);
        vm.assume(params.tickLower < 0 && 0 < params.tickUpper); // two-sided liquidity

        PositionConfig memory config =
            PositionConfig({poolKey: nativeKey, tickLower: params.tickLower, tickUpper: params.tickUpper});

        // mint the position with native token liquidity
        uint256 tokenId = lpm.nextTokenId();
        mintWithNative(SQRT_PRICE_1_1, config, uint256(params.liquidityDelta), ActionConstants.MSG_SENDER, ZERO_BYTES);

        // donate to generate fee revenue
        uint256 feeRevenue0 = 1e18;
        uint256 feeRevenue1 = 0.1e18;
        donateRouter.donate{value: 1e18}(nativeKey, feeRevenue0, feeRevenue1, ZERO_BYTES);

        uint256 balance0Before = address(this).balance;
        uint256 balance1Before = currency1.balanceOfSelf();

        Plan memory planner = Planner.init();
        planner.add(
            Actions.DECREASE_LIQUIDITY, abi.encode(tokenId, 0, MIN_SLIPPAGE_DECREASE, MIN_SLIPPAGE_DECREASE, ZERO_BYTES)
        );

        bytes memory calls = planner.finalizeModifyLiquidityWithTakePair(config.poolKey, ActionConstants.MSG_SENDER);
        lpm.modifyLiquidities(calls, _deadline);
        BalanceDelta delta = getLastDelta();

        assertApproxEqAbs(currency0.balanceOfSelf() - balance0Before, feeRevenue0, 1 wei); // TODO: fuzzer off by 1 wei
        assertEq(currency0.balanceOfSelf() - balance0Before, uint128(delta.amount0()));
        assertEq(currency1.balanceOfSelf() - balance1Before, uint128(delta.amount1()));
    }

    // this test fails unless subscribe is payable
    function test_multicall_mint_subscribe_native() public {
        uint256 tokenId = lpm.nextTokenId();

        PositionConfig memory config = PositionConfig({poolKey: nativeKey, tickLower: -60, tickUpper: 60});

        Plan memory plan = Planner.init();
        plan.add(
            Actions.MINT_POSITION,
            abi.encode(
                config.poolKey,
                config.tickLower,
                config.tickUpper,
                100e18,
                MAX_SLIPPAGE_INCREASE,
                MAX_SLIPPAGE_INCREASE,
                address(this),
                ZERO_BYTES
            )
        );
        plan.add(Actions.CLOSE_CURRENCY, abi.encode(config.poolKey.currency0));
        plan.add(Actions.CLOSE_CURRENCY, abi.encode(config.poolKey.currency1));
        plan.add(Actions.SWEEP, abi.encode(CurrencyLibrary.ADDRESS_ZERO, address(this)));
        bytes memory actions = plan.encode();

        bytes[] memory calls = new bytes[](2);

        calls[0] = abi.encodeWithSelector(lpm.modifyLiquidities.selector, actions, _deadline);
        calls[1] = abi.encodeWithSelector(lpm.subscribe.selector, tokenId, sub, ZERO_BYTES);

        lpm.multicall{value: 10e18}(calls);

        uint256 liquidity = lpm.getPositionLiquidity(tokenId);

        assertEq(liquidity, 100e18);
        assertEq(sub.notifySubscribeCount(), 1);
    }
}
