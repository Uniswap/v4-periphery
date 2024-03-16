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
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {LiquidityAmounts} from "../../contracts/libraries/LiquidityAmounts.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";

import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";

import {INonfungiblePositionManager} from "../../contracts/interfaces/INonfungiblePositionManager.sol";
import {NonfungiblePositionManager} from "../../contracts/NonfungiblePositionManager.sol";
import {
    LiquidityPosition,
    LiquidityPositionId,
    LiquidityPositionIdLibrary
} from "../../contracts/types/LiquidityPositionId.sol";

import {LiquidityFuzzers} from "../shared/fuzz/LiquidityFuzzers.sol";

contract FeeCollectionTest is Test, Deployers, GasSnapshot, LiquidityFuzzers {
    using FixedPointMathLib for uint256;
    using CurrencyLibrary for Currency;
    using LiquidityPositionIdLibrary for LiquidityPosition;

    NonfungiblePositionManager lpm;

    PoolId poolId;
    address alice = makeAddr("ALICE");
    address bob = makeAddr("BOB");

    // unused value for the fuzz helper functions
    uint128 constant DEAD_VALUE = 6969.6969 ether;

    function setUp() public {
        Deployers.deployFreshManagerAndRouters();
        Deployers.deployMintAndApprove2Currencies();

        (key, poolId) = initPool(currency0, currency1, IHooks(address(0)), 3000, SQRT_RATIO_1_1, ZERO_BYTES);

        lpm = new NonfungiblePositionManager(manager);

        IERC20(Currency.unwrap(currency0)).approve(address(lpm), type(uint256).max);
        IERC20(Currency.unwrap(currency1)).approve(address(lpm), type(uint256).max);
    }

    function test_collect(int24 tickLower, int24 tickUpper, uint128 liquidityDelta) public {
        uint256 tokenId;
        liquidityDelta = uint128(bound(liquidityDelta, 100e18, 100_000e18)); // require nontrivial amount of liquidity
        (tokenId, tickLower, tickUpper, liquidityDelta,) =
            createFuzzyLiquidity(lpm, address(this), key, tickLower, tickUpper, liquidityDelta, ZERO_BYTES);
        vm.assume(tickLower < -60 && 60 < tickUpper); // require two-sided liquidity

        // swap to create fees
        uint256 swapAmount = 0.01e18;
        swap(key, false, int256(swapAmount), ZERO_BYTES);

        // collect fees
        uint256 balance0Before = currency0.balanceOfSelf();
        uint256 balance1Before = currency1.balanceOfSelf();
        BalanceDelta delta = lpm.collect(tokenId, address(this), ZERO_BYTES);

        assertEq(delta.amount0(), 0, "a");

        // express key.fee as wad (i.e. 3000 = 0.003e18)
        uint256 feeWad = uint256(key.fee).mulDivDown(FixedPointMathLib.WAD, 1_000_000);
        assertApproxEqAbs(uint256(int256(-delta.amount1())), swapAmount.mulWadDown(feeWad), 1 wei);
    }

    // two users with the same range; one user cannot collect the other's fees
    function test_collect_sameRange(
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidityDeltaAlice,
        uint128 liquidityDeltaBob
    ) public {
        uint256 tokenIdAlice;
        uint256 tokenIdBob;
        liquidityDeltaAlice = uint128(bound(liquidityDeltaAlice, 100e18, 100_000e18)); // require nontrivial amount of liquidity
        liquidityDeltaBob = uint128(bound(liquidityDeltaBob, 100e18, 100_000e18));

        (tickLower, tickUpper, liquidityDeltaAlice) =
            createFuzzyLiquidityParams(key, tickLower, tickUpper, liquidityDeltaAlice);
        vm.assume(tickLower < -60 && 60 < tickUpper); // require two-sided liquidity
        (,,liquidityDeltaBob) =
            createFuzzyLiquidityParams(key, tickLower, tickUpper, liquidityDeltaBob);
        
        vm.prank(alice);
        (tokenIdAlice,) = lpm.mint(LiquidityPosition({key: key, tickLower: tickLower, tickUpper: tickUpper}), liquidityDeltaAlice, block.timestamp + 1, alice, ZERO_BYTES);
        
        vm.prank(bob);
        (tokenIdBob,) = lpm.mint(LiquidityPosition({key: key, tickLower: tickLower, tickUpper: tickUpper}), liquidityDeltaBob, block.timestamp + 1, alice, ZERO_BYTES);
        
        
        // swap to create fees
        uint256 swapAmount = 0.01e18;
        swap(key, false, int256(swapAmount), ZERO_BYTES);

        // alice collects only her fees
        vm.prank(alice);
        BalanceDelta delta = lpm.collect(tokenIdAlice, alice, ZERO_BYTES);
    }

    function test_collect_donate() public {}
    function test_collect_donate_sameRange() public {}

    function test_mintTransferCollect() public {}
    function test_mintTransferIncrease() public {}
    function test_mintTransferDecrease() public {}
}
