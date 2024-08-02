// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
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
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {IERC721} from "@openzeppelin/contracts/interfaces/IERC721.sol";

import {IPositionManager} from "../../src/interfaces/IPositionManager.sol";
import {Actions} from "../../src/libraries/Actions.sol";
import {PositionManager} from "../../src/PositionManager.sol";
import {Constants} from "../../src/libraries/Constants.sol";

import {LiquidityFuzzers} from "../shared/fuzz/LiquidityFuzzers.sol";
import {PosmTestSetup} from "../shared/PosmTestSetup.sol";
import {Planner, Plan} from "../shared/Planner.sol";
import {PositionConfig, PositionConfigLibrary} from "../../src/libraries/PositionConfig.sol";

contract PositionManagerTest is Test, PosmTestSetup, LiquidityFuzzers {
    using FixedPointMathLib for uint256;
    using CurrencyLibrary for Currency;
    using PositionConfigLibrary for PositionConfig;
    using Planner for Plan;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using SafeCast for *;

    PoolId poolId;

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();

        // This is needed to receive return deltas from modifyLiquidity calls.
        deployPosmHookSavesDelta();

        currency0 = CurrencyLibrary.NATIVE;
        (nativeKey, poolId) = initPool(currency0, currency1, IHooks(hook), 3000, SQRT_PRICE_1_1, ZERO_BYTES);

        deployPosm(manager);
        // currency0 is the native token so only execute approvals for currency1.
        approvePosmCurrency(currency1);

        vm.deal(address(this), type(uint256).max);
    }

    function test_fuzz_mint_native(IPoolManager.ModifyLiquidityParams memory params) public {
        params = createFuzzyLiquidityParams(nativeKey, params, SQRT_PRICE_1_1);
        vm.assume(params.tickLower < 0 && 0 < params.tickUpper); // two-sided liquidity

        uint256 liquidityToAdd =
            params.liquidityDelta < 0 ? uint256(-params.liquidityDelta) : uint256(params.liquidityDelta);
        PositionConfig memory config =
            PositionConfig({poolKey: nativeKey, tickLower: params.tickLower, tickUpper: params.tickUpper});

        uint256 balance0Before = currency0.balanceOfSelf();
        uint256 balance1Before = currency1.balanceOfSelf();

        uint256 tokenId = lpm.nextTokenId();
        bytes memory calls = getMintEncoded(config, liquidityToAdd, Constants.MSG_SENDER, ZERO_BYTES);

        (uint256 amount0,) = LiquidityAmounts.getAmountsForLiquidity(
            SQRT_PRICE_1_1,
            TickMath.getSqrtPriceAtTick(params.tickLower),
            TickMath.getSqrtPriceAtTick(params.tickUpper),
            liquidityToAdd.toUint128()
        );
        // add extra wei because modifyLiquidities may be rounding up, LiquidityAmounts is imprecise?
        lpm.modifyLiquidities{value: amount0 + 1}(calls, _deadline);
        BalanceDelta delta = getLastDelta();

        bytes32 positionId =
            Position.calculatePositionKey(address(lpm), config.tickLower, config.tickUpper, bytes32(tokenId));
        (uint256 liquidity,,) = manager.getPositionInfo(config.poolKey.toId(), positionId);

        assertEq(liquidity, uint256(params.liquidityDelta));
        assertEq(balance0Before - currency0.balanceOfSelf(), uint256(int256(-delta.amount0())), "incorrect amount0");
        assertEq(balance1Before - currency1.balanceOfSelf(), uint256(int256(-delta.amount1())), "incorrect amount1");
    }

    // minting with excess native tokens are returned to caller
    function test_fuzz_mint_native_excess_withClose(IPoolManager.ModifyLiquidityParams memory params) public {
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
                config, liquidityToAdd, MAX_SLIPPAGE_INCREASE, MAX_SLIPPAGE_INCREASE, Constants.MSG_SENDER, ZERO_BYTES
            )
        );
        planner.add(Actions.CLOSE_CURRENCY, abi.encode(nativeKey.currency0));
        planner.add(Actions.CLOSE_CURRENCY, abi.encode(nativeKey.currency1));
        // sweep the excess eth
        planner.add(Actions.SWEEP, abi.encode(currency0, Constants.MSG_SENDER));

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

        bytes32 positionId =
            Position.calculatePositionKey(address(lpm), config.tickLower, config.tickUpper, bytes32(tokenId));
        (uint256 liquidity,,) = manager.getPositionInfo(config.poolKey.toId(), positionId);
        assertEq(liquidity, uint256(params.liquidityDelta));

        // only paid the delta amount, with excess tokens returned to caller
        assertEq(balance0Before - currency0.balanceOfSelf(), uint256(int256(-delta.amount0())));
        assertEq(balance0Before - currency0.balanceOfSelf(), amount0 + 1); // TODO: off by one??
        assertEq(balance1Before - currency1.balanceOfSelf(), uint256(int256(-delta.amount1())));
    }

    function test_fuzz_mint_native_excess_withSettlePair(IPoolManager.ModifyLiquidityParams memory params) public {
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
            abi.encode(config, liquidityToAdd, MAX_SLIPPAGE_INCREASE, MAX_SLIPPAGE_INCREASE, address(this), ZERO_BYTES)
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

        bytes32 positionId =
            Position.calculatePositionKey(address(lpm), config.tickLower, config.tickUpper, bytes32(tokenId));
        (uint256 liquidity,,) = manager.getPositionInfo(config.poolKey.toId(), positionId);
        assertEq(liquidity, uint256(params.liquidityDelta));

        // only paid the delta amount, with excess tokens returned to caller
        assertEq(balance0Before - currency0.balanceOfSelf(), uint256(int256(-delta.amount0())));
        assertEq(balance0Before - currency0.balanceOfSelf(), amount0 + 1); // TODO: off by one??
        assertEq(balance1Before - currency1.balanceOfSelf(), uint256(int256(-delta.amount1())));
    }

    function test_fuzz_burn_native_emptyPosition(IPoolManager.ModifyLiquidityParams memory params) public {
        uint256 balance0Start = address(this).balance;
        uint256 balance1Start = currency1.balanceOfSelf();

        params = createFuzzyLiquidityParams(nativeKey, params, SQRT_PRICE_1_1);
        vm.assume(params.tickLower < 0 && 0 < params.tickUpper); // two-sided liquidity

        uint256 liquidityToAdd =
            params.liquidityDelta < 0 ? uint256(-params.liquidityDelta) : uint256(params.liquidityDelta);
        PositionConfig memory config =
            PositionConfig({poolKey: nativeKey, tickLower: params.tickLower, tickUpper: params.tickUpper});

        uint256 tokenId = lpm.nextTokenId();
        mintWithNative(SQRT_PRICE_1_1, config, liquidityToAdd, Constants.MSG_SENDER, ZERO_BYTES);

        bytes32 positionId =
            Position.calculatePositionKey(address(lpm), config.tickLower, config.tickUpper, bytes32(tokenId));
        (uint256 liquidity,,) = manager.getPositionInfo(config.poolKey.toId(), positionId);
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

        (liquidity,,) = manager.getPositionInfo(config.poolKey.toId(), positionId);
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
        lpm.ownerOf(1);

        // no tokens were lost, TODO: fuzzer showing off by 1 sometimes
        assertApproxEqAbs(currency0.balanceOfSelf(), balance0Start, 1 wei);
        assertApproxEqAbs(address(this).balance, balance0Start, 1 wei);
        assertApproxEqAbs(currency1.balanceOfSelf(), balance1Start, 1 wei);
    }

    function test_fuzz_burn_native_nonEmptyPosition(IPoolManager.ModifyLiquidityParams memory params) public {
        uint256 balance0Start = address(this).balance;
        uint256 balance1Start = currency1.balanceOfSelf();

        params = createFuzzyLiquidityParams(nativeKey, params, SQRT_PRICE_1_1);
        vm.assume(params.tickLower < 0 && 0 < params.tickUpper); // two-sided liquidity

        uint256 liquidityToAdd =
            params.liquidityDelta < 0 ? uint256(-params.liquidityDelta) : uint256(params.liquidityDelta);
        PositionConfig memory config =
            PositionConfig({poolKey: nativeKey, tickLower: params.tickLower, tickUpper: params.tickUpper});

        uint256 tokenId = lpm.nextTokenId();
        mintWithNative(SQRT_PRICE_1_1, config, liquidityToAdd, Constants.MSG_SENDER, ZERO_BYTES);

        bytes32 positionId =
            Position.calculatePositionKey(address(lpm), config.tickLower, config.tickUpper, bytes32(tokenId));
        (uint256 liquidity,,) = manager.getPositionInfo(config.poolKey.toId(), positionId);
        assertEq(liquidity, uint256(params.liquidityDelta));

        // burn liquidity
        uint256 balance0BeforeBurn = currency0.balanceOfSelf();
        uint256 balance1BeforeBurn = currency1.balanceOfSelf();

        burn(tokenId, config, ZERO_BYTES);
        BalanceDelta deltaBurn = getLastDelta();

        (liquidity,,) = manager.getPositionInfo(config.poolKey.toId(), positionId);
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
        lpm.ownerOf(1);

        // no tokens were lost, TODO: fuzzer showing off by 1 sometimes
        assertApproxEqAbs(currency0.balanceOfSelf(), balance0Start, 1 wei);
        assertApproxEqAbs(address(this).balance, balance0Start, 1 wei);
        assertApproxEqAbs(currency1.balanceOfSelf(), balance1Start, 1 wei);
    }

    function test_fuzz_increaseLiquidity_native(IPoolManager.ModifyLiquidityParams memory params) public {
        // fuzz for the range
        params = createFuzzyLiquidityParams(nativeKey, params, SQRT_PRICE_1_1);
        vm.assume(params.tickLower < -60 && 60 < params.tickUpper); // two-sided liquidity

        // TODO: figure out if we can fuzz the increase liquidity delta. we're annoyingly getting TickLiquidityOverflow
        uint256 liquidityToAdd = 1e18;
        PositionConfig memory config =
            PositionConfig({poolKey: nativeKey, tickLower: params.tickLower, tickUpper: params.tickUpper});

        // mint the position with native token liquidity
        uint256 tokenId = lpm.nextTokenId();
        mintWithNative(SQRT_PRICE_1_1, config, liquidityToAdd, Constants.MSG_SENDER, ZERO_BYTES);

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
        bytes32 positionId =
            Position.calculatePositionKey(address(lpm), config.tickLower, config.tickUpper, bytes32(tokenId));
        (uint256 liquidity,,) = manager.getPositionInfo(config.poolKey.toId(), positionId);
        assertEq(liquidity, liquidityToAdd + liquidityToAdd); // liquidity was doubled

        // verify native token balances changed as expected
        assertEq(balance0Before - currency0.balanceOfSelf(), amount0 + 1 wei);
        assertEq(balance0Before - currency0.balanceOfSelf(), uint256(int256(-delta.amount0())));
        assertEq(balance1Before - currency1.balanceOfSelf(), uint256(int256(-delta.amount1())));
    }

    // overpaying native tokens on increase liquidity is returned to caller
    function test_fuzz_increaseLiquidity_native_excess_withClose(IPoolManager.ModifyLiquidityParams memory params)
        public
    {
        // fuzz for the range
        params = createFuzzyLiquidityParams(nativeKey, params, SQRT_PRICE_1_1);
        vm.assume(params.tickLower < 0 && 0 < params.tickUpper); // two-sided liquidity

        // TODO: figure out if we can fuzz the increase liquidity delta. we're annoyingly getting TickLiquidityOverflow
        uint256 liquidityToAdd = 1e18;
        PositionConfig memory config =
            PositionConfig({poolKey: nativeKey, tickLower: params.tickLower, tickUpper: params.tickUpper});

        // mint the position with native token liquidity
        uint256 tokenId = lpm.nextTokenId();
        mintWithNative(SQRT_PRICE_1_1, config, liquidityToAdd, Constants.MSG_SENDER, ZERO_BYTES);

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
            abi.encode(tokenId, config, liquidityToAdd, MAX_SLIPPAGE_INCREASE, MAX_SLIPPAGE_INCREASE, ZERO_BYTES)
        );
        planner.add(Actions.CLOSE_CURRENCY, abi.encode(nativeKey.currency0));
        planner.add(Actions.CLOSE_CURRENCY, abi.encode(nativeKey.currency1));
        // sweep the excess eth
        planner.add(Actions.SWEEP, abi.encode(currency0, Constants.MSG_SENDER));
        bytes memory calls = planner.encode();

        lpm.modifyLiquidities{value: amount0 * 2}(calls, _deadline); // overpay on increase liquidity
        BalanceDelta delta = getLastDelta();

        // verify position liquidity increased
        bytes32 positionId =
            Position.calculatePositionKey(address(lpm), config.tickLower, config.tickUpper, bytes32(tokenId));
        (uint256 liquidity,,) = manager.getPositionInfo(config.poolKey.toId(), positionId);
        assertEq(liquidity, liquidityToAdd + liquidityToAdd); // liquidity was doubled

        // verify native token balances changed as expected, with overpaid tokens returned
        assertEq(balance0Before - currency0.balanceOfSelf(), amount0 + 1 wei);
        assertEq(balance0Before - currency0.balanceOfSelf(), uint256(int256(-delta.amount0())));
        assertEq(balance1Before - currency1.balanceOfSelf(), uint256(int256(-delta.amount1())));
    }

    function test_fuzz_increaseLiquidity_native_excess_withSettlePair(IPoolManager.ModifyLiquidityParams memory params)
        public
    {
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
            abi.encode(tokenId, config, liquidityToAdd, MAX_SLIPPAGE_INCREASE, MAX_SLIPPAGE_INCREASE, ZERO_BYTES)
        );
        planner.add(Actions.SETTLE_PAIR, abi.encode(nativeKey.currency0, nativeKey.currency1));
        // sweep the excess eth
        planner.add(Actions.SWEEP, abi.encode(currency0, address(this)));
        bytes memory calls = planner.encode();

        lpm.modifyLiquidities{value: amount0 * 2}(calls, _deadline); // overpay on increase liquidity
        BalanceDelta delta = getLastDelta();

        // verify position liquidity increased
        bytes32 positionId =
            Position.calculatePositionKey(address(lpm), config.tickLower, config.tickUpper, bytes32(tokenId));
        (uint256 liquidity,,) = manager.getPositionInfo(config.poolKey.toId(), positionId);
        assertEq(liquidity, liquidityToAdd + liquidityToAdd); // liquidity was doubled

        // verify native token balances changed as expected, with overpaid tokens returned
        assertEq(balance0Before - currency0.balanceOfSelf(), amount0 + 1 wei);
        assertEq(balance0Before - currency0.balanceOfSelf(), uint256(int256(-delta.amount0())));
        assertEq(balance1Before - currency1.balanceOfSelf(), uint256(int256(-delta.amount1())));
    }

    function test_fuzz_decreaseLiquidity_native(
        IPoolManager.ModifyLiquidityParams memory params,
        uint256 decreaseLiquidityDelta
    ) public {
        params = createFuzzyLiquidityParams(nativeKey, params, SQRT_PRICE_1_1);
        vm.assume(params.tickLower < 0 && 0 < params.tickUpper); // two-sided liquidity
        decreaseLiquidityDelta = bound(decreaseLiquidityDelta, 1, uint256(params.liquidityDelta));

        PositionConfig memory config =
            PositionConfig({poolKey: nativeKey, tickLower: params.tickLower, tickUpper: params.tickUpper});

        // mint the position with native token liquidity
        uint256 tokenId = lpm.nextTokenId();
        mintWithNative(SQRT_PRICE_1_1, config, uint256(params.liquidityDelta), Constants.MSG_SENDER, ZERO_BYTES);

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

        bytes32 positionId =
            Position.calculatePositionKey(address(lpm), config.tickLower, config.tickUpper, bytes32(tokenId));
        (uint256 liquidity,,) = manager.getPositionInfo(config.poolKey.toId(), positionId);
        assertEq(liquidity, uint256(params.liquidityDelta) - decreaseLiquidityDelta);

        // verify native token balances changed as expected
        assertApproxEqAbs(currency0.balanceOfSelf() - balance0Before, amount0, 1 wei);
        assertEq(currency0.balanceOfSelf() - balance0Before, uint128(delta.amount0()));
        assertEq(currency1.balanceOfSelf() - balance1Before, uint128(delta.amount1()));
    }

    function test_fuzz_collect_native(IPoolManager.ModifyLiquidityParams memory params) public {
        params = createFuzzyLiquidityParams(nativeKey, params, SQRT_PRICE_1_1);
        vm.assume(params.tickLower < 0 && 0 < params.tickUpper); // two-sided liquidity

        PositionConfig memory config =
            PositionConfig({poolKey: nativeKey, tickLower: params.tickLower, tickUpper: params.tickUpper});

        // mint the position with native token liquidity
        uint256 tokenId = lpm.nextTokenId();
        mintWithNative(SQRT_PRICE_1_1, config, uint256(params.liquidityDelta), Constants.MSG_SENDER, ZERO_BYTES);

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
}
