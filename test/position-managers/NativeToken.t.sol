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
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";

import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {IERC721} from "@openzeppelin/contracts/interfaces/IERC721.sol";

import {IPositionManager, Actions} from "../../src/interfaces/IPositionManager.sol";
import {PositionManager} from "../../src/PositionManager.sol";
import {LiquidityRange, LiquidityRangeId, LiquidityRangeIdLibrary} from "../../src/types/LiquidityRange.sol";

import {LiquidityFuzzers} from "../shared/fuzz/LiquidityFuzzers.sol";
import {PosmTestSetup} from "../shared/PosmTestSetup.sol";
import {Planner} from "../utils/Planner.sol";

contract PositionManagerTest is Test, PosmTestSetup, LiquidityFuzzers {
    using FixedPointMathLib for uint256;
    using CurrencyLibrary for Currency;
    using LiquidityRangeIdLibrary for LiquidityRange;
    using Planner for Planner.Plan;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using SafeCast for *;

    PoolId poolId;

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();

        currency0 = CurrencyLibrary.NATIVE;
        (key, poolId) = initPool(currency0, currency1, IHooks(address(0)), 3000, SQRT_PRICE_1_1, ZERO_BYTES);

        lpm = new PositionManager(manager);
        IERC20(Currency.unwrap(currency1)).approve(address(lpm), type(uint256).max);

        vm.deal(address(this), type(uint256).max);
    }

    function test_mint_native(IPoolManager.ModifyLiquidityParams memory params) public {
        params = createFuzzyLiquidityParams(key, params, SQRT_PRICE_1_1);
        vm.assume(params.tickLower < 0 && 0 < params.tickUpper); // two-sided liquidity

        uint256 liquidityToAdd =
            params.liquidityDelta < 0 ? uint256(-params.liquidityDelta) : uint256(params.liquidityDelta);
        LiquidityRange memory range =
            LiquidityRange({poolKey: key, tickLower: params.tickLower, tickUpper: params.tickUpper});

        uint256 balance0Before = currency0.balanceOfSelf();
        uint256 balance1Before = currency1.balanceOfSelf();

        uint256 tokenId = lpm.nextTokenId();
        bytes memory calls = getMintEncoded(range, liquidityToAdd, address(this), ZERO_BYTES);

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
            keccak256(abi.encodePacked(address(lpm), range.tickLower, range.tickUpper, bytes32(tokenId)));
        (uint256 liquidity,,) = manager.getPositionInfo(range.poolKey.toId(), positionId);

        assertEq(liquidity, uint256(params.liquidityDelta));
        assertEq(balance0Before - currency0.balanceOfSelf(), uint256(int256(-delta.amount0())), "incorrect amount0");
        assertEq(balance1Before - currency1.balanceOfSelf(), uint256(int256(-delta.amount1())), "incorrect amount1");
    }

    // minting with excess native tokens are returned to caller
    function test_mint_native_excess(IPoolManager.ModifyLiquidityParams memory params) public {
        params = createFuzzyLiquidityParams(key, params, SQRT_PRICE_1_1);
        vm.assume(params.tickLower < 0 && 0 < params.tickUpper); // two-sided liquidity

        uint256 liquidityToAdd =
            params.liquidityDelta < 0 ? uint256(-params.liquidityDelta) : uint256(params.liquidityDelta);
        LiquidityRange memory range =
            LiquidityRange({poolKey: key, tickLower: params.tickLower, tickUpper: params.tickUpper});

        uint256 balance0Before = currency0.balanceOfSelf();
        uint256 balance1Before = currency1.balanceOfSelf();

        uint256 tokenId = lpm.nextTokenId();
        bytes memory calls = getMintEncoded(range, liquidityToAdd, address(this), ZERO_BYTES);

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
            keccak256(abi.encodePacked(address(lpm), range.tickLower, range.tickUpper, bytes32(tokenId)));
        (uint256 liquidity,,) = manager.getPositionInfo(range.poolKey.toId(), positionId);
        assertEq(liquidity, uint256(params.liquidityDelta));

        // only paid the delta amount, with excess tokens returned to caller
        assertEq(balance0Before - currency0.balanceOfSelf(), uint256(int256(-delta.amount0())));
        assertEq(balance0Before - currency0.balanceOfSelf(), amount0 + 1); // TODO: off by one??
        assertEq(balance1Before - currency1.balanceOfSelf(), uint256(int256(-delta.amount1())));
    }

    // function test_burn_native(IPoolManager.ModifyLiquidityParams memory params) public {
    //     uint256 balance0Start = currency0.balanceOfSelf();
    //     uint256 balance1Start = currency1.balanceOfSelf();

    //     // create liquidity we can burn
    //     uint256 tokenId;
    //     (tokenId, params) = addFuzzyLiquidity(lpm, address(this), key, params, SQRT_PRICE_1_1, ZERO_BYTES);
    //     LiquidityRange memory range =
    //         LiquidityRange({poolKey: key, tickLower: params.tickLower, tickUpper: params.tickUpper});
    //     assertEq(tokenId, 1);
    //     assertEq(lpm.ownerOf(1), address(this));

    //     bytes32 positionId =
    //         keccak256(abi.encodePacked(address(lpm), range.tickLower, range.tickUpper, bytes32(tokenId)));
    //     (uint256 liquidity,,) = manager.getPositionInfo(range.poolKey.toId(), positionId);

    //     assertEq(liquidity, uint256(params.liquidityDelta));

    //     // burn liquidity
    //     uint256 balance0BeforeBurn = currency0.balanceOfSelf();
    //     uint256 balance1BeforeBurn = currency1.balanceOfSelf();

    //     BalanceDelta deltaDecrease = decreaseLiquidity(tokenId, liquidity, ZERO_BYTES);
    //     burn(tokenId);

    //     (liquidity,,) = manager.getPositionInfo(range.poolKey.toId(), positionId);

    //     assertEq(liquidity, 0);

    //     // TODO: slightly off by 1 bip (0.0001%)
    //     assertApproxEqRel(
    //         currency0.balanceOfSelf(), balance0BeforeBurn + uint256(uint128(deltaDecrease.amount0())), 0.0001e18
    //     );
    //     assertApproxEqRel(
    //         currency1.balanceOfSelf(), balance1BeforeBurn + uint256(uint128(deltaDecrease.amount1())), 0.0001e18
    //     );

    //     // OZ 721 will revert if the token does not exist
    //     vm.expectRevert();
    //     lpm.ownerOf(1);

    //     // no tokens were lost, TODO: fuzzer showing off by 1 sometimes
    //     assertApproxEqAbs(currency0.balanceOfSelf(), balance0Start, 1 wei);
    //     assertApproxEqAbs(currency1.balanceOfSelf(), balance1Start, 1 wei);
    // }

    // function test_increaseLiquidity_mative(IPoolManager.ModifyLiquidityParams memory params, uint256 increaseLiquidityDelta) public {}

    // function test_decreaseLiquidity_native(IPoolManager.ModifyLiquidityParams memory params, uint256 decreaseLiquidityDelta)
    //     public
    // {
    //     uint256 tokenId;
    //     (tokenId, params) = addFuzzyLiquidity(lpm, address(this), key, params, SQRT_PRICE_1_1, ZERO_BYTES);
    //     vm.assume(0 < decreaseLiquidityDelta);
    //     vm.assume(decreaseLiquidityDelta < uint256(type(int256).max));
    //     vm.assume(int256(decreaseLiquidityDelta) <= params.liquidityDelta);

    //     LiquidityRange memory range =
    //         LiquidityRange({poolKey: key, tickLower: params.tickLower, tickUpper: params.tickUpper});

    //     decreaseLiquidity(tokenId, decreaseLiquidityDelta, ZERO_BYTES);

    //     bytes32 positionId =
    //         keccak256(abi.encodePacked(address(lpm), range.tickLower, range.tickUpper, bytes32(tokenId)));
    //     (uint256 liquidity,,) = manager.getPositionInfo(range.poolKey.toId(), positionId);

    //     assertEq(liquidity, uint256(params.liquidityDelta) - decreaseLiquidityDelta);
    // }

    // function test_collect_native() public {}
}
