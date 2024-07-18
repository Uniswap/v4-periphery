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
import {LiquidityAmounts} from "../../contracts/libraries/LiquidityAmounts.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";

import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";

import {NonfungiblePositionManager} from "../../contracts/NonfungiblePositionManager.sol";
import {LiquidityRange, LiquidityRangeId, LiquidityRangeIdLibrary} from "../../contracts/types/LiquidityRange.sol";

import {LiquidityFuzzers} from "../shared/fuzz/LiquidityFuzzers.sol";

import {LiquidityOperations} from "../shared/LiquidityOperations.sol";

import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";

contract FeeCollectionTest is Test, Deployers, GasSnapshot, LiquidityFuzzers, LiquidityOperations {
    using FixedPointMathLib for uint256;
    using CurrencyLibrary for Currency;
    using LiquidityRangeIdLibrary for LiquidityRange;

    PoolId poolId;
    address alice = makeAddr("ALICE");
    address bob = makeAddr("BOB");

    uint256 constant STARTING_USER_BALANCE = 10_000_000 ether;

    // expresses the fee as a wad (i.e. 3000 = 0.003e18)
    uint256 FEE_WAD;

    function setUp() public {
        Deployers.deployFreshManagerAndRouters();
        Deployers.deployMintAndApprove2Currencies();

        (key, poolId) = initPool(currency0, currency1, IHooks(address(0)), 3000, SQRT_PRICE_1_1, ZERO_BYTES);
        FEE_WAD = uint256(key.fee).mulDivDown(FixedPointMathLib.WAD, 1_000_000);

        lpm = new NonfungiblePositionManager(manager);
        IERC20(Currency.unwrap(currency0)).approve(address(lpm), type(uint256).max);
        IERC20(Currency.unwrap(currency1)).approve(address(lpm), type(uint256).max);

        // Give tokens to Alice and Bob, with approvals
        IERC20(Currency.unwrap(currency0)).transfer(alice, STARTING_USER_BALANCE);
        IERC20(Currency.unwrap(currency1)).transfer(alice, STARTING_USER_BALANCE);
        IERC20(Currency.unwrap(currency0)).transfer(bob, STARTING_USER_BALANCE);
        IERC20(Currency.unwrap(currency1)).transfer(bob, STARTING_USER_BALANCE);
        vm.startPrank(alice);
        IERC20(Currency.unwrap(currency0)).approve(address(lpm), type(uint256).max);
        IERC20(Currency.unwrap(currency1)).approve(address(lpm), type(uint256).max);
        vm.stopPrank();
        vm.startPrank(bob);
        IERC20(Currency.unwrap(currency0)).approve(address(lpm), type(uint256).max);
        IERC20(Currency.unwrap(currency1)).approve(address(lpm), type(uint256).max);
        vm.stopPrank();
    }

    // TODO: we dont accept collecting fees as 6909 yet
    // function test_collect_6909(IPoolManager.ModifyLiquidityParams memory params) public {
    //     params.liquidityDelta = bound(params.liquidityDelta, 10e18, 10_000e18);
    //     uint256 tokenId;
    //     (tokenId, params) = createFuzzyLiquidity(lpm, address(this), key, params, SQRT_PRICE_1_1, ZERO_BYTES);
    //     vm.assume(params.tickLower < 0 && 0 < params.tickUpper); // require two-sided liquidity

    //     // swap to create fees
    //     uint256 swapAmount = 0.01e18;
    //     swap(key, false, -int256(swapAmount), ZERO_BYTES);

    //     // collect fees
    //     BalanceDelta delta = _collect(tokenId, address(this), ZERO_BYTES, true);

    //     assertEq(delta.amount0(), 0);

    //     assertApproxEqAbs(uint256(int256(delta.amount1())), swapAmount.mulWadDown(FEE_WAD), 1 wei);

    //     assertEq(uint256(int256(delta.amount1())), manager.balanceOf(address(this), currency1.toId()));
    // }

    function test_collect_erc20(IPoolManager.ModifyLiquidityParams memory params) public {
        params.liquidityDelta = bound(params.liquidityDelta, 10e18, 10_000e18);
        uint256 tokenId;
        (tokenId, params) = createFuzzyLiquidity(lpm, address(this), key, params, SQRT_PRICE_1_1, ZERO_BYTES);
        vm.assume(params.tickLower < 0 && 0 < params.tickUpper); // require two-sided liquidity

        // swap to create fees
        uint256 swapAmount = 0.01e18;
        swap(key, false, -int256(swapAmount), ZERO_BYTES);

        BalanceDelta feesAccrued = lpm.feesOwed(tokenId);

        // collect fees
        uint256 balance0Before = currency0.balanceOfSelf();
        uint256 balance1Before = currency1.balanceOfSelf();
        BalanceDelta delta = _collect(tokenId, address(this), ZERO_BYTES);

        // express key.fee as wad (i.e. 3000 = 0.003e18)
        assertApproxEqAbs(uint256(int256(delta.amount1())), swapAmount.mulWadDown(FEE_WAD), 1 wei);
        assertEq(delta.amount0(), feesAccrued.amount0());
        assertEq(delta.amount1(), feesAccrued.amount1());
        assertEq(uint256(int256(delta.amount0())), currency0.balanceOfSelf() - balance0Before);
        assertEq(uint256(int256(delta.amount1())), currency1.balanceOfSelf() - balance1Before);
    }

    // TODO: we dont accept collecting fees as 6909 yet
    // two users with the same range; one user cannot collect the other's fees
    // function test_collect_sameRange_6909(IPoolManager.ModifyLiquidityParams memory params, uint256 liquidityDeltaBob)
    //     public
    // {
    //     params.liquidityDelta = bound(params.liquidityDelta, 10e18, 10_000e18);
    //     params = createFuzzyLiquidityParams(key, params, SQRT_PRICE_1_1);
    //     vm.assume(params.tickLower < 0 && 0 < params.tickUpper); // require two-sided liquidity

    //     liquidityDeltaBob = bound(liquidityDeltaBob, 100e18, 100_000e18);

    //     LiquidityRange memory range =
    //         LiquidityRange({poolKey: key, tickLower: params.tickLower, tickUpper: params.tickUpper});
    //     vm.prank(alice);
    //     _mint(range, uint256(params.liquidityDelta), block.timestamp + 1, alice, ZERO_BYTES);
    //     uint256 tokenIdAlice = lpm.nextTokenId() - 1;

    //     vm.prank(bob);
    //     _mint(range, liquidityDeltaBob, block.timestamp + 1, bob, ZERO_BYTES);
    //     uint256 tokenIdBob = lpm.nextTokenId() - 1;

    //     // swap to create fees
    //     uint256 swapAmount = 0.01e18;
    //     swap(key, false, -int256(swapAmount), ZERO_BYTES);

    //     // alice collects only her fees
    //     vm.prank(alice);
    //     BalanceDelta delta = _collect(tokenIdAlice, alice, ZERO_BYTES, true);
    //     assertEq(uint256(uint128(delta.amount0())), manager.balanceOf(alice, currency0.toId()));
    //     assertEq(uint256(uint128(delta.amount1())), manager.balanceOf(alice, currency1.toId()));
    //     assertTrue(delta.amount1() != 0);

    //     // bob collects only his fees
    //     vm.prank(bob);
    //     delta = _collect(tokenIdBob, bob, ZERO_BYTES, true);
    //     assertEq(uint256(uint128(delta.amount0())), manager.balanceOf(bob, currency0.toId()));
    //     assertEq(uint256(uint128(delta.amount1())), manager.balanceOf(bob, currency1.toId()));
    //     assertTrue(delta.amount1() != 0);

    //     // position manager holds no fees now
    //     assertApproxEqAbs(manager.balanceOf(address(lpm), currency0.toId()), 0, 1 wei);
    //     assertApproxEqAbs(manager.balanceOf(address(lpm), currency1.toId()), 0, 1 wei);
    // }

    function test_collect_sameRange_erc20(IPoolManager.ModifyLiquidityParams memory params, uint256 liquidityDeltaBob)
        public
    {
        params.liquidityDelta = bound(params.liquidityDelta, 10e18, 10_000e18);
        params = createFuzzyLiquidityParams(key, params, SQRT_PRICE_1_1);
        vm.assume(params.tickLower < 0 && 0 < params.tickUpper); // require two-sided liquidity

        liquidityDeltaBob = bound(liquidityDeltaBob, 100e18, 100_000e18);

        LiquidityRange memory range =
            LiquidityRange({poolKey: key, tickLower: params.tickLower, tickUpper: params.tickUpper});
        vm.prank(alice);
        _mint(range, uint256(params.liquidityDelta), block.timestamp + 1, alice, ZERO_BYTES);
        uint256 tokenIdAlice = lpm.nextTokenId() - 1;

        vm.prank(bob);
        _mint(range, liquidityDeltaBob, block.timestamp + 1, bob, ZERO_BYTES);
        uint256 tokenIdBob = lpm.nextTokenId() - 1;

        // confirm the positions are same range
        (, LiquidityRange memory rangeAlice,) = lpm.tokenPositions(tokenIdAlice);
        (, LiquidityRange memory rangeBob,) = lpm.tokenPositions(tokenIdBob);
        assertEq(rangeAlice.tickLower, rangeBob.tickLower);
        assertEq(rangeAlice.tickUpper, rangeBob.tickUpper);

        // swap to create fees
        uint256 swapAmount = 0.01e18;
        swap(key, false, -int256(swapAmount), ZERO_BYTES);

        // alice collects only her fees
        uint256 balance0AliceBefore = currency0.balanceOf(alice);
        uint256 balance1AliceBefore = currency1.balanceOf(alice);
        vm.startPrank(alice);
        BalanceDelta delta = _collect(tokenIdAlice, alice, ZERO_BYTES);
        vm.stopPrank();
        uint256 balance0AliceAfter = currency0.balanceOf(alice);
        uint256 balance1AliceAfter = currency1.balanceOf(alice);

        assertEq(balance0AliceBefore, balance0AliceAfter);
        assertEq(uint256(uint128(delta.amount1())), balance1AliceAfter - balance1AliceBefore);
        assertTrue(delta.amount1() != 0);

        // bob collects only his fees
        uint256 balance0BobBefore = currency0.balanceOf(bob);
        uint256 balance1BobBefore = currency1.balanceOf(bob);
        vm.startPrank(bob);
        delta = _collect(tokenIdBob, bob, ZERO_BYTES);
        vm.stopPrank();
        uint256 balance0BobAfter = currency0.balanceOf(bob);
        uint256 balance1BobAfter = currency1.balanceOf(bob);

        assertEq(balance0BobBefore, balance0BobAfter);
        assertEq(uint256(uint128(delta.amount1())), balance1BobAfter - balance1BobBefore);
        assertTrue(delta.amount1() != 0);

        // position manager holds no fees now
        assertApproxEqAbs(manager.balanceOf(address(lpm), currency0.toId()), 0, 1 wei);
        assertApproxEqAbs(manager.balanceOf(address(lpm), currency1.toId()), 0, 1 wei);
    }

    function test_collect_donate() public {
        LiquidityRange memory range = LiquidityRange({poolKey: key, tickLower: -120, tickUpper: 120});
        _mint(range, 10e18, block.timestamp + 1, address(this), ZERO_BYTES);
        uint256 tokenId = lpm.nextTokenId() - 1;

        // donate to generate fee revenue
        uint256 feeRevenue = 1e18;
        donateRouter.donate(key, feeRevenue, feeRevenue, ZERO_BYTES);

        BalanceDelta feesAccrued = lpm.feesOwed(tokenId);

        // collect fees
        uint256 balance0Before = currency0.balanceOfSelf();
        uint256 balance1Before = currency1.balanceOfSelf();
        BalanceDelta delta = _collect(tokenId, address(this), ZERO_BYTES);

        assertApproxEqAbs(uint256(int256(delta.amount0())), feeRevenue, 1 wei);
        assertApproxEqAbs(uint256(int256(delta.amount1())), feeRevenue, 1 wei);
        assertEq(delta.amount0(), feesAccrued.amount0());
        assertEq(delta.amount1(), feesAccrued.amount1());

        assertEq(uint256(int256(delta.amount0())), currency0.balanceOfSelf() - balance0Before);
        assertEq(uint256(int256(delta.amount1())), currency1.balanceOfSelf() - balance1Before);
    }

    function test_collect_donate_sameRange() public {
        // alice and bob create liquidity on the same range [-120, 120]
        LiquidityRange memory range = LiquidityRange({poolKey: key, tickLower: -120, tickUpper: 120});

        // alice provisions 3x the amount of liquidity as bob
        uint256 liquidityAlice = 3000e18;
        uint256 liquidityBob = 1000e18;

        vm.startPrank(alice);
        _mint(range, liquidityAlice, block.timestamp + 1, alice, ZERO_BYTES);
        vm.stopPrank();
        uint256 tokenIdAlice = lpm.nextTokenId() - 1;

        vm.startPrank(bob);
        _mint(range, liquidityBob, block.timestamp + 1, bob, ZERO_BYTES);
        vm.stopPrank();
        uint256 tokenIdBob = lpm.nextTokenId() - 1;

        // donate to generate fee revenue
        uint256 feeRevenue0 = 1e18;
        uint256 feeRevenue1 = 0.1e18;
        donateRouter.donate(key, feeRevenue0, feeRevenue1, ZERO_BYTES);

        {
            // alice collects her share
            BalanceDelta feesAccruedAlice = lpm.feesOwed(tokenIdAlice);
            assertApproxEqAbs(
                uint128(feesAccruedAlice.amount0()),
                feeRevenue0.mulDivDown(liquidityAlice, liquidityAlice + liquidityBob),
                1 wei
            );
            assertApproxEqAbs(
                uint128(feesAccruedAlice.amount1()),
                feeRevenue1.mulDivDown(liquidityAlice, liquidityAlice + liquidityBob),
                1 wei
            );

            uint256 balance0BeforeAlice = currency0.balanceOf(alice);
            uint256 balance1BeforeAlice = currency1.balanceOf(alice);
            vm.startPrank(alice);
            BalanceDelta deltaAlice = _collect(tokenIdAlice, alice, ZERO_BYTES);
            vm.stopPrank();

            assertEq(deltaAlice.amount0(), feesAccruedAlice.amount0());
            assertEq(deltaAlice.amount1(), feesAccruedAlice.amount1());
            assertEq(currency0.balanceOf(alice), balance0BeforeAlice + uint256(uint128(feesAccruedAlice.amount0())));
            assertEq(currency1.balanceOf(alice), balance1BeforeAlice + uint256(uint128(feesAccruedAlice.amount1())));
        }

        {
            // bob collects his share
            BalanceDelta feesAccruedBob = lpm.feesOwed(tokenIdBob);
            assertApproxEqAbs(
                uint128(feesAccruedBob.amount0()),
                feeRevenue0.mulDivDown(liquidityBob, liquidityAlice + liquidityBob),
                1 wei
            );
            assertApproxEqAbs(
                uint128(feesAccruedBob.amount1()),
                feeRevenue1.mulDivDown(liquidityBob, liquidityAlice + liquidityBob),
                1 wei
            );

            uint256 balance0BeforeBob = currency0.balanceOf(bob);
            uint256 balance1BeforeBob = currency1.balanceOf(bob);
            vm.startPrank(bob);
            BalanceDelta deltaBob = _collect(tokenIdBob, bob, ZERO_BYTES);
            vm.stopPrank();

            assertEq(deltaBob.amount0(), feesAccruedBob.amount0());
            assertEq(deltaBob.amount1(), feesAccruedBob.amount1());
            assertEq(currency0.balanceOf(bob), balance0BeforeBob + uint256(uint128(feesAccruedBob.amount0())));
            assertEq(currency1.balanceOf(bob), balance1BeforeBob + uint256(uint128(feesAccruedBob.amount1())));
        }
    }

    /// @dev Alice and Bob create liquidity on the same range, and decrease their liquidity
    // Even though their positions are the same range, they are unique positions in pool manager.
    function test_decreaseLiquidity_sameRange_exact() public {
        // alice and bob create liquidity on the same range [-120, 120]
        LiquidityRange memory range = LiquidityRange({poolKey: key, tickLower: -120, tickUpper: 120});

        // alice provisions 3x the amount of liquidity as bob
        uint256 liquidityAlice = 3000e18;
        uint256 liquidityBob = 1000e18;

        vm.prank(alice);
        BalanceDelta lpDeltaAlice = _mint(range, liquidityAlice, block.timestamp + 1, alice, ZERO_BYTES);
        uint256 tokenIdAlice = lpm.nextTokenId() - 1;

        uint256 aliceBalance0Before = IERC20(Currency.unwrap(currency0)).balanceOf(address(alice));
        uint256 aliceBalance1Before = IERC20(Currency.unwrap(currency1)).balanceOf(address(alice));

        vm.prank(bob);
        BalanceDelta lpDeltaBob = _mint(range, liquidityBob, block.timestamp + 1, bob, ZERO_BYTES);
        uint256 tokenIdBob = lpm.nextTokenId() - 1;

        uint256 bobBalance0Before = IERC20(Currency.unwrap(currency0)).balanceOf(address(bob));
        uint256 bobBalance1Before = IERC20(Currency.unwrap(currency1)).balanceOf(address(bob));

        // swap to create fees
        uint256 swapAmount = 0.001e18;
        swap(key, true, -int256(swapAmount), ZERO_BYTES); // zeroForOne is true, so zero is the input
        swap(key, false, -int256(swapAmount), ZERO_BYTES); // move the price back, // zeroForOne is false, so one is the input

        // alice decreases liquidity
        vm.startPrank(alice);
        lpm.approve(address(this), tokenIdAlice);
        _decreaseLiquidity(tokenIdAlice, liquidityAlice, ZERO_BYTES);
        vm.stopPrank();

        uint256 tolerance = 0.000000001 ether;

        // alice has accrued her principle liquidity + any fees in token0
        assertApproxEqAbs(
            IERC20(Currency.unwrap(currency0)).balanceOf(address(alice)) - aliceBalance0Before,
            uint256(int256(-lpDeltaAlice.amount0())) + swapAmount.mulWadDown(FEE_WAD) * 3 / 4,
            tolerance
        );
        // alice has accrued her principle liquidity + any fees in token1
        assertApproxEqAbs(
            IERC20(Currency.unwrap(currency1)).balanceOf(address(alice)) - aliceBalance1Before,
            uint256(int256(-lpDeltaAlice.amount1())) + swapAmount.mulWadDown(FEE_WAD) * 3 / 4,
            tolerance
        );

        // bob decreases half of his liquidity
        vm.startPrank(bob);
        lpm.approve(address(this), tokenIdBob);
        _decreaseLiquidity(tokenIdBob, liquidityBob / 2, ZERO_BYTES);
        vm.stopPrank();

        // bob has accrued half his principle liquidity + any fees in token0
        assertApproxEqAbs(
            IERC20(Currency.unwrap(currency0)).balanceOf(address(bob)) - bobBalance0Before,
            uint256(int256(-lpDeltaBob.amount0()) / 2) + swapAmount.mulWadDown(FEE_WAD) * 1 / 4,
            tolerance
        );
        // bob has accrued half his principle liquidity + any fees in token0
        assertApproxEqAbs(
            IERC20(Currency.unwrap(currency1)).balanceOf(address(bob)) - bobBalance1Before,
            uint256(int256(-lpDeltaBob.amount1()) / 2) + swapAmount.mulWadDown(FEE_WAD) * 1 / 4,
            tolerance
        );
    }
}
