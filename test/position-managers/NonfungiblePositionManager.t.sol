// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {GasSnapshot} from "forge-gas-snapshot/GasSnapshot.sol";
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

import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";

import {INonfungiblePositionManager, Actions} from "../../src/interfaces/INonfungiblePositionManager.sol";
import {NonfungiblePositionManager} from "../../src/NonfungiblePositionManager.sol";
import {LiquidityRange, LiquidityRangeId, LiquidityRangeIdLibrary} from "../../src/types/LiquidityRange.sol";

import {LiquidityFuzzers} from "../shared/fuzz/LiquidityFuzzers.sol";

import {LiquidityOperations} from "../shared/LiquidityOperations.sol";
import {Planner} from "../utils/Planner.sol";

contract NonfungiblePositionManagerTest is Test, Deployers, GasSnapshot, LiquidityFuzzers, LiquidityOperations {
    using FixedPointMathLib for uint256;
    using CurrencyLibrary for Currency;
    using LiquidityRangeIdLibrary for LiquidityRange;
    using Planner for Planner.Plan;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    PoolId poolId;
    address alice = makeAddr("ALICE");

    function setUp() public {
        Deployers.deployFreshManagerAndRouters();
        Deployers.deployMintAndApprove2Currencies();

        (key, poolId) = initPool(currency0, currency1, IHooks(address(0)), 3000, SQRT_PRICE_1_1, ZERO_BYTES);

        lpm = new NonfungiblePositionManager(manager);

        IERC20(Currency.unwrap(currency0)).approve(address(lpm), type(uint256).max);
        IERC20(Currency.unwrap(currency1)).approve(address(lpm), type(uint256).max);
    }

    function test_modifyLiquidities_reverts_mismatchedLengths() public {
        Planner.Plan memory planner = Planner.init();
        planner = planner.add(Actions.MINT, abi.encode("test"));
        planner = planner.add(Actions.BURN, abi.encode("test"));

        bytes[] memory badParams = new bytes[](1);

        vm.expectRevert(INonfungiblePositionManager.MismatchedLengths.selector);
        lpm.modifyLiquidities(abi.encode(planner.actions, badParams), block.timestamp + 1);
    }

    function test_mint_withLiquidityDelta(IPoolManager.ModifyLiquidityParams memory params) public {
        params = createFuzzyLiquidityParams(key, params, SQRT_PRICE_1_1);
        // liquidity is a uint
        uint256 liquidityToAdd =
            params.liquidityDelta < 0 ? uint256(-params.liquidityDelta) : uint256(params.liquidityDelta);
        LiquidityRange memory range =
            LiquidityRange({poolKey: key, tickLower: params.tickLower, tickUpper: params.tickUpper});

        uint256 balance0Before = currency0.balanceOfSelf();
        uint256 balance1Before = currency1.balanceOfSelf();

        uint256 tokenId = lpm.nextTokenId();
        BalanceDelta delta = _mint(range, liquidityToAdd, address(this), ZERO_BYTES);

        assertEq(tokenId, 1);
        assertEq(lpm.ownerOf(tokenId), address(this));

        bytes32 positionId =
            keccak256(abi.encodePacked(address(lpm), range.tickLower, range.tickUpper, bytes32(tokenId)));
        (uint256 liquidity,,) = manager.getPositionInfo(range.poolKey.toId(), positionId);

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

        LiquidityRange memory range = LiquidityRange({poolKey: key, tickLower: tickLower, tickUpper: tickUpper});

        uint256 balance0Before = currency0.balanceOfSelf();
        uint256 balance1Before = currency1.balanceOfSelf();

        uint256 tokenId = lpm.nextTokenId();
        BalanceDelta delta = _mint(range, liquidityToAdd, address(this), ZERO_BYTES);

        uint256 balance0After = currency0.balanceOfSelf();
        uint256 balance1After = currency1.balanceOfSelf();

        assertEq(tokenId, 1);
        assertEq(lpm.ownerOf(1), address(this));

        assertEq(uint256(int256(-delta.amount0())), amount0Desired);
        assertEq(uint256(int256(-delta.amount1())), amount1Desired);
        assertEq(balance0Before - balance0After, uint256(int256(-delta.amount0())));
        assertEq(balance1Before - balance1After, uint256(int256(-delta.amount1())));
    }

    function test_mint_recipient(IPoolManager.ModifyLiquidityParams memory seedParams) public {
        IPoolManager.ModifyLiquidityParams memory params = createFuzzyLiquidityParams(key, seedParams, SQRT_PRICE_1_1);
        uint256 liquidityToAdd =
            params.liquidityDelta < 0 ? uint256(-params.liquidityDelta) : uint256(params.liquidityDelta);

        LiquidityRange memory range =
            LiquidityRange({poolKey: key, tickLower: params.tickLower, tickUpper: params.tickUpper});

        uint256 tokenId = lpm.nextTokenId();
        _mint(range, liquidityToAdd, address(alice), ZERO_BYTES);

        assertEq(tokenId, 1);
        assertEq(lpm.ownerOf(tokenId), alice);
    }

    // function test_mint_slippageRevert(int24 tickLower, int24 tickUpper, uint256 amount0Desired, uint256 amount1Desired)
    //     public
    // {
    //     (tickLower, tickUpper) = createFuzzyLiquidityParams(key, tickLower, tickUpper, DEAD_VALUE);
    //     vm.assume(tickLower < 0 && 0 < tickUpper);

    //     (amount0Desired, amount1Desired) =
    //         createFuzzyAmountDesired(key, tickLower, tickUpper, amount0Desired, amount1Desired);
    //     vm.assume(0.00001e18 < amount0Desired);
    //     vm.assume(0.00001e18 < amount1Desired);

    //     uint256 amount0Min = amount0Desired - 1;
    //     uint256 amount1Min = amount1Desired - 1;

    //     LiquidityRange memory range = LiquidityRange({poolKey: key, tickLower: tickLower, tickUpper: tickUpper});
    //     INonfungiblePositionManager.MintParams memory params = INonfungiblePositionManager.MintParams({
    //         range: range,
    //         amount0Desired: amount0Desired,
    //         amount1Desired: amount1Desired,
    //         amount0Min: amount0Min,
    //         amount1Min: amount1Min,
    //         deadline: block.timestamp + 1,
    //         recipient: address(this),
    //         hookData: ZERO_BYTES
    //     });

    //     // seed some liquidity so we can move the price
    //     modifyLiquidityRouter.modifyLiquidity(
    //         key,
    //         IPoolManager.ModifyLiquidityParams({
    //             tickLower: TickMath.minUsableTick(key.tickSpacing),
    //             tickUpper: TickMath.maxUsableTick(key.tickSpacing),
    //             liquidityDelta: 100_000e18,
    //             salt: 0
    //         }),
    //         ZERO_BYTES
    //     );

    //     // swap to move the price
    //     swap(key, true, -1000e18, ZERO_BYTES);

    //     // will revert because amount0Min and amount1Min are very strict
    //     vm.expectRevert();
    //     lpm.mint(params);
    // }

    function test_burn(IPoolManager.ModifyLiquidityParams memory params) public {
        uint256 balance0Start = currency0.balanceOfSelf();
        uint256 balance1Start = currency1.balanceOfSelf();

        // create liquidity we can burn
        uint256 tokenId;
        (tokenId, params) = createFuzzyLiquidity(lpm, address(this), key, params, SQRT_PRICE_1_1, ZERO_BYTES);
        LiquidityRange memory range =
            LiquidityRange({poolKey: key, tickLower: params.tickLower, tickUpper: params.tickUpper});
        assertEq(tokenId, 1);
        assertEq(lpm.ownerOf(1), address(this));

        bytes32 positionId =
            keccak256(abi.encodePacked(address(lpm), range.tickLower, range.tickUpper, bytes32(tokenId)));
        (uint256 liquidity,,) = manager.getPositionInfo(range.poolKey.toId(), positionId);

        assertEq(liquidity, uint256(params.liquidityDelta));

        // burn liquidity
        uint256 balance0BeforeBurn = currency0.balanceOfSelf();
        uint256 balance1BeforeBurn = currency1.balanceOfSelf();

        BalanceDelta deltaDecrease = _decreaseLiquidity(tokenId, liquidity, ZERO_BYTES);
        _burn(tokenId);

        (liquidity,,) = manager.getPositionInfo(range.poolKey.toId(), positionId);

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
        assertApproxEqAbs(currency1.balanceOfSelf(), balance1Start, 1 wei);
    }

    function test_decreaseLiquidity(IPoolManager.ModifyLiquidityParams memory params, uint256 decreaseLiquidityDelta)
        public
    {
        uint256 tokenId;
        (tokenId, params) = createFuzzyLiquidity(lpm, address(this), key, params, SQRT_PRICE_1_1, ZERO_BYTES);
        vm.assume(0 < decreaseLiquidityDelta);
        vm.assume(decreaseLiquidityDelta < uint256(type(int256).max));
        vm.assume(int256(decreaseLiquidityDelta) <= params.liquidityDelta);

        LiquidityRange memory range =
            LiquidityRange({poolKey: key, tickLower: params.tickLower, tickUpper: params.tickUpper});

        _decreaseLiquidity(tokenId, decreaseLiquidityDelta, ZERO_BYTES);

        bytes32 positionId =
            keccak256(abi.encodePacked(address(lpm), range.tickLower, range.tickUpper, bytes32(tokenId)));
        (uint256 liquidity,,) = manager.getPositionInfo(range.poolKey.toId(), positionId);

        assertEq(liquidity, uint256(params.liquidityDelta) - decreaseLiquidityDelta);
    }

    // function test_decreaseLiquidity_collectFees(
    //     IPoolManager.ModifyLiquidityParams memory params,
    //     uint256 decreaseLiquidityDelta
    // ) public {
    //     uint256 tokenId;
    //     (tokenId, params) = createFuzzyLiquidity(lpm, address(this), key, params, SQRT_PRICE_1_1, ZERO_BYTES);
    //     vm.assume(params.tickLower < 0 && 0 < params.tickUpper); // require two-sided liquidity
    //     vm.assume(0 < decreaseLiquidityDelta);
    //     vm.assume(decreaseLiquidityDelta < uint256(type(int256).max));
    //     vm.assume(int256(decreaseLiquidityDelta) <= params.liquidityDelta);

    //     LiquidityRange memory range = LiquidityRange({poolKey: key, tickLower: params.tickLower, tickUpper: params.tickUpper});

    //     // swap to create fees
    //     uint256 swapAmount = 0.01e18;
    //     swap(key, false, int256(swapAmount), ZERO_BYTES);

    //     uint256 balance0Before = currency0.balanceOfSelf();
    //     uint256 balance1Before = currency1.balanceOfSelf();
    //             BalanceDelta delta = lpm.decreaseLiquidity(tokenId, decreaseLiquidityDelta, ZERO_BYTES, false);
    //     (uint256 liquidity,,,,) = lpm.positions(address(this), range.toId());
    //     assertEq(liquidity, uint256(params.liquidityDelta) - decreaseLiquidityDelta);

    //     // express key.fee as wad (i.e. 3000 = 0.003e18)
    //     uint256 feeWad = uint256(key.fee).mulDivDown(FixedPointMathLib.WAD, 1_000_000);

    //     assertEq(currency0.balanceOfSelf() - balance0Before, uint256(int256(-delta.amount0())), "boo");
    //     assertEq(currency1.balanceOfSelf() - balance1Before, uint256(int256(-delta.amount1())), "guh");
    // }

    function test_mintTransferBurn() public {}
    function test_mintTransferCollect() public {}
    function test_mintTransferIncrease() public {}
    function test_mintTransferDecrease() public {}

    function test_initialize(IPoolManager.ModifyLiquidityParams memory params) public {
        // initialize a new pool and add liquidity
        key = PoolKey({currency0: currency0, currency1: currency1, fee: 0, tickSpacing: 10, hooks: IHooks(address(0))});
        lpm.initializePool(key, SQRT_PRICE_1_1, ZERO_BYTES);

        params = createFuzzyLiquidityParams(key, params, SQRT_PRICE_1_1);

        // add liquidity to verify pool initialized
        LiquidityRange memory range =
            LiquidityRange({poolKey: key, tickLower: params.tickLower, tickUpper: params.tickUpper});
        _mint(range, 100e18, address(this), ZERO_BYTES);

        assertEq(lpm.ownerOf(1), address(this));
    }
}
