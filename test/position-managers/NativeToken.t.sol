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
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import {Position} from "@uniswap/v4-core/src/libraries/Position.sol";

import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {IERC721} from "@openzeppelin/contracts/interfaces/IERC721.sol";

import {IPositionManager, Actions} from "../../src/interfaces/IPositionManager.sol";
import {PositionManager} from "../../src/PositionManager.sol";

import {LiquidityFuzzers} from "../shared/fuzz/LiquidityFuzzers.sol";
import {PosmTestSetup} from "../shared/PosmTestSetup.sol";
import {Planner} from "../shared/Planner.sol";
import {PositionConfig, PositionConfigLibrary} from "../../src/libraries/PositionConfig.sol";

contract PositionManagerTest is Test, PosmTestSetup, LiquidityFuzzers {
    using FixedPointMathLib for uint256;
    using CurrencyLibrary for Currency;
    using PositionConfigLibrary for PositionConfig;
    using Planner for Planner.Plan;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using SafeCast for *;

    PoolId poolId;

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();

        currency0 = CurrencyLibrary.NATIVE;
        (nativeKey, poolId) = initPool(currency0, currency1, IHooks(address(0)), 3000, SQRT_PRICE_1_1, ZERO_BYTES);

        lpm = new PositionManager(manager);
        IERC20(Currency.unwrap(currency1)).approve(address(lpm), type(uint256).max);

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
        bytes memory calls = getMintEncoded(config, liquidityToAdd, address(this), ZERO_BYTES);

        (uint256 amount0,) = LiquidityAmounts.getAmountsForLiquidity(
            SQRT_PRICE_1_1,
            TickMath.getSqrtPriceAtTick(params.tickLower),
            TickMath.getSqrtPriceAtTick(params.tickUpper),
            liquidityToAdd.toUint128()
        );
        // add extra wei because modifyLiquidities may be rounding up, LiquidityAmounts is imprecise?
        bytes[] memory result = lpm.modifyLiquidities{value: amount0 + 1}(calls, _deadline);
        BalanceDelta delta = abi.decode(result[0], (BalanceDelta));

        bytes32 positionId =
            Position.calculatePositionKey(address(lpm), config.tickLower, config.tickUpper, bytes32(tokenId));
        (uint256 liquidity,,) = manager.getPositionInfo(config.poolKey.toId(), positionId);

        assertEq(liquidity, uint256(params.liquidityDelta));
        assertEq(balance0Before - currency0.balanceOfSelf(), uint256(int256(-delta.amount0())), "incorrect amount0");
        assertEq(balance1Before - currency1.balanceOfSelf(), uint256(int256(-delta.amount1())), "incorrect amount1");
    }

    // minting with excess native tokens are returned to caller
    function test_fuzz_mint_native_excess(IPoolManager.ModifyLiquidityParams memory params) public {
        params = createFuzzyLiquidityParams(nativeKey, params, SQRT_PRICE_1_1);
        vm.assume(params.tickLower < 0 && 0 < params.tickUpper); // two-sided liquidity

        uint256 liquidityToAdd =
            params.liquidityDelta < 0 ? uint256(-params.liquidityDelta) : uint256(params.liquidityDelta);
        PositionConfig memory config =
            PositionConfig({poolKey: nativeKey, tickLower: params.tickLower, tickUpper: params.tickUpper});

        uint256 balance0Before = currency0.balanceOfSelf();
        uint256 balance1Before = currency1.balanceOfSelf();

        uint256 tokenId = lpm.nextTokenId();
        bytes memory calls = getMintEncoded(config, liquidityToAdd, address(this), ZERO_BYTES);

        (uint256 amount0,) = LiquidityAmounts.getAmountsForLiquidity(
            SQRT_PRICE_1_1,
            TickMath.getSqrtPriceAtTick(params.tickLower),
            TickMath.getSqrtPriceAtTick(params.tickUpper),
            liquidityToAdd.toUint128()
        );

        // Mint with excess native tokens
        bytes[] memory result = lpm.modifyLiquidities{value: amount0 * 2 + 1}(calls, _deadline);
        BalanceDelta delta = abi.decode(result[0], (BalanceDelta));

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
        mintWithNative(SQRT_PRICE_1_1, config, liquidityToAdd, address(this), ZERO_BYTES);

        bytes32 positionId =
            Position.calculatePositionKey(address(lpm), config.tickLower, config.tickUpper, bytes32(tokenId));
        (uint256 liquidity,,) = manager.getPositionInfo(config.poolKey.toId(), positionId);
        assertEq(liquidity, uint256(params.liquidityDelta));

        // burn liquidity
        uint256 balance0BeforeBurn = currency0.balanceOfSelf();
        uint256 balance1BeforeBurn = currency1.balanceOfSelf();

        BalanceDelta deltaDecrease = decreaseLiquidity(tokenId, config, liquidity, ZERO_BYTES);
        BalanceDelta deltaBurn = burn(tokenId, config, ZERO_BYTES);
        assertEq(deltaBurn.amount0(), 0);
        assertEq(deltaBurn.amount1(), 0);

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
        mintWithNative(SQRT_PRICE_1_1, config, liquidityToAdd, address(this), ZERO_BYTES);

        bytes32 positionId =
            Position.calculatePositionKey(address(lpm), config.tickLower, config.tickUpper, bytes32(tokenId));
        (uint256 liquidity,,) = manager.getPositionInfo(config.poolKey.toId(), positionId);
        assertEq(liquidity, uint256(params.liquidityDelta));

        // burn liquidity
        uint256 balance0BeforeBurn = currency0.balanceOfSelf();
        uint256 balance1BeforeBurn = currency1.balanceOfSelf();

        BalanceDelta deltaBurn = burn(tokenId, config, ZERO_BYTES);

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

        bytes memory calls = getIncreaseEncoded(tokenId, config, liquidityToAdd, ZERO_BYTES); // double the liquidity
        bytes[] memory result = lpm.modifyLiquidities{value: amount0 + 1 wei}(calls, _deadline); // TODO: off by one wei
        BalanceDelta delta = abi.decode(result[0], (BalanceDelta));

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
    function test_fuzz_increaseLiquidity_native_excess(IPoolManager.ModifyLiquidityParams memory params) public {
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

        bytes memory calls = getIncreaseEncoded(tokenId, config, liquidityToAdd, ZERO_BYTES); // double the liquidity
        bytes[] memory result = lpm.modifyLiquidities{value: amount0 * 2}(calls, _deadline); // overpay on increase liquidity
        BalanceDelta delta = abi.decode(result[0], (BalanceDelta));

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
        mintWithNative(SQRT_PRICE_1_1, config, uint256(params.liquidityDelta), address(this), ZERO_BYTES);

        uint256 balance0Before = address(this).balance;
        uint256 balance1Before = currency1.balanceOfSelf();

        // decrease liquidity and receive native tokens
        (uint256 amount0,) = LiquidityAmounts.getAmountsForLiquidity(
            SQRT_PRICE_1_1,
            TickMath.getSqrtPriceAtTick(params.tickLower),
            TickMath.getSqrtPriceAtTick(params.tickUpper),
            uint128(decreaseLiquidityDelta)
        );
        BalanceDelta delta = decreaseLiquidity(tokenId, config, decreaseLiquidityDelta, ZERO_BYTES);

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
        mintWithNative(SQRT_PRICE_1_1, config, uint256(params.liquidityDelta), address(this), ZERO_BYTES);

        // donate to generate fee revenue
        uint256 feeRevenue0 = 1e18;
        uint256 feeRevenue1 = 0.1e18;
        donateRouter.donate{value: 1e18}(nativeKey, feeRevenue0, feeRevenue1, ZERO_BYTES);

        uint256 balance0Before = address(this).balance;
        uint256 balance1Before = currency1.balanceOfSelf();
        BalanceDelta delta = collect(tokenId, config, ZERO_BYTES);

        assertApproxEqAbs(currency0.balanceOfSelf() - balance0Before, feeRevenue0, 1 wei); // TODO: fuzzer off by 1 wei
        assertEq(currency0.balanceOfSelf() - balance0Before, uint128(delta.amount0()));
        assertEq(currency1.balanceOfSelf() - balance1Before, uint128(delta.amount1()));
    }
}
