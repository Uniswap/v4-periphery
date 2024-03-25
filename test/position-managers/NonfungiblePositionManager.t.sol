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
import {LiquidityRange, LiquidityRangeId, LiquidityRangeIdLibrary} from "../../contracts/types/LiquidityRange.sol";

import {LiquidityFuzzers} from "../shared/fuzz/LiquidityFuzzers.sol";

contract NonfungiblePositionManagerTest is Test, Deployers, GasSnapshot, LiquidityFuzzers {
    using FixedPointMathLib for uint256;
    using CurrencyLibrary for Currency;
    using LiquidityRangeIdLibrary for LiquidityRange;

    NonfungiblePositionManager lpm;

    PoolId poolId;
    address alice = makeAddr("ALICE");

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

    function test_mint_withLiquidityDelta(int24 tickLower, int24 tickUpper, uint128 liquidityDelta) public {
        (tickLower, tickUpper, liquidityDelta) = createFuzzyLiquidityParams(key, tickLower, tickUpper, liquidityDelta);
        LiquidityRange memory position = LiquidityRange({key: key, tickLower: tickLower, tickUpper: tickUpper});

        uint256 balance0Before = currency0.balanceOfSelf();
        uint256 balance1Before = currency1.balanceOfSelf();
        (uint256 tokenId, BalanceDelta delta) =
            lpm.mint(position, liquidityDelta, block.timestamp + 1, address(this), ZERO_BYTES);
        uint256 balance0After = currency0.balanceOfSelf();
        uint256 balance1After = currency1.balanceOfSelf();

        assertEq(tokenId, 1);
        assertEq(lpm.ownerOf(1), address(this));
        assertEq(lpm.liquidityOf(address(this), position.toId()), liquidityDelta);
        assertEq(balance0Before - balance0After, uint256(int256(delta.amount0())), "incorrect amount0");
        assertEq(balance1Before - balance1After, uint256(int256(delta.amount1())), "incorrect amount1");
    }

    function test_mint(int24 tickLower, int24 tickUpper, uint256 amount0Desired, uint256 amount1Desired) public {
        (tickLower, tickUpper,) = createFuzzyLiquidityParams(key, tickLower, tickUpper, DEAD_VALUE);
        (amount0Desired, amount1Desired) =
            createFuzzyAmountDesired(key, tickLower, tickUpper, amount0Desired, amount1Desired);

        LiquidityRange memory range = LiquidityRange({key: key, tickLower: tickLower, tickUpper: tickUpper});

        uint256 balance0Before = currency0.balanceOfSelf();
        uint256 balance1Before = currency1.balanceOfSelf();
        INonfungiblePositionManager.MintParams memory params = INonfungiblePositionManager.MintParams({
            range: range,
            amount0Desired: amount0Desired,
            amount1Desired: amount1Desired,
            amount0Min: 0,
            amount1Min: 0,
            deadline: block.timestamp + 1,
            recipient: address(this),
            hookData: ZERO_BYTES
        });
        (uint256 tokenId, BalanceDelta delta) = lpm.mint(params);
        uint256 balance0After = currency0.balanceOfSelf();
        uint256 balance1After = currency1.balanceOfSelf();

        assertEq(tokenId, 1);
        assertEq(lpm.ownerOf(1), address(this));
        assertEq(balance0Before - balance0After, uint256(int256(delta.amount0())));
        assertEq(balance1Before - balance1After, uint256(int256(delta.amount1())));
    }

    // minting with perfect token ratios will use all of the tokens
    function test_mint_perfect() public {
        int24 tickLower = -int24(key.tickSpacing);
        int24 tickUpper = int24(key.tickSpacing);
        uint256 amount0Desired = 100e18;
        uint256 amount1Desired = 100e18;
        LiquidityRange memory range = LiquidityRange({key: key, tickLower: tickLower, tickUpper: tickUpper});

        uint256 balance0Before = currency0.balanceOfSelf();
        uint256 balance1Before = currency1.balanceOfSelf();
        INonfungiblePositionManager.MintParams memory params = INonfungiblePositionManager.MintParams({
            range: range,
            amount0Desired: amount0Desired,
            amount1Desired: amount1Desired,
            amount0Min: amount0Desired,
            amount1Min: amount1Desired,
            deadline: block.timestamp + 1,
            recipient: address(this),
            hookData: ZERO_BYTES
        });
        (uint256 tokenId, BalanceDelta delta) = lpm.mint(params);
        uint256 balance0After = currency0.balanceOfSelf();
        uint256 balance1After = currency1.balanceOfSelf();

        assertEq(tokenId, 1);
        assertEq(lpm.ownerOf(1), address(this));
        assertEq(uint256(int256(delta.amount0())), amount0Desired);
        assertEq(uint256(int256(delta.amount1())), amount1Desired);
        assertEq(balance0Before - balance0After, uint256(int256(delta.amount0())));
        assertEq(balance1Before - balance1After, uint256(int256(delta.amount1())));
    }

    function test_mint_recipient(int24 tickLower, int24 tickUpper, uint256 amount0Desired, uint256 amount1Desired)
        public
    {
        (tickLower, tickUpper,) = createFuzzyLiquidityParams(key, tickLower, tickUpper, DEAD_VALUE);
        (amount0Desired, amount1Desired) =
            createFuzzyAmountDesired(key, tickLower, tickUpper, amount0Desired, amount1Desired);

        LiquidityRange memory range = LiquidityRange({key: key, tickLower: tickLower, tickUpper: tickUpper});
        INonfungiblePositionManager.MintParams memory params = INonfungiblePositionManager.MintParams({
            range: range,
            amount0Desired: amount0Desired,
            amount1Desired: amount1Desired,
            amount0Min: 0,
            amount1Min: 0,
            deadline: block.timestamp + 1,
            recipient: alice,
            hookData: ZERO_BYTES
        });
        (uint256 tokenId,) = lpm.mint(params);
        assertEq(tokenId, 1);
        assertEq(lpm.ownerOf(tokenId), alice);
    }

    function test_mint_slippageRevert(int24 tickLower, int24 tickUpper, uint256 amount0Desired, uint256 amount1Desired)
        public
    {
        (tickLower, tickUpper,) = createFuzzyLiquidityParams(key, tickLower, tickUpper, DEAD_VALUE);
        vm.assume(tickLower < 0);
        vm.assume(tickUpper > 0);

        (amount0Desired, amount1Desired) =
            createFuzzyAmountDesired(key, tickLower, tickUpper, amount0Desired, amount1Desired);
        vm.assume(0.00001e18 < amount0Desired);
        vm.assume(0.00001e18 < amount1Desired);

        uint256 amount0Min = amount0Desired - 1;
        uint256 amount1Min = amount1Desired - 1;

        LiquidityRange memory range = LiquidityRange({key: key, tickLower: tickLower, tickUpper: tickUpper});
        INonfungiblePositionManager.MintParams memory params = INonfungiblePositionManager.MintParams({
            range: range,
            amount0Desired: amount0Desired,
            amount1Desired: amount1Desired,
            amount0Min: amount0Min,
            amount1Min: amount1Min,
            deadline: block.timestamp + 1,
            recipient: address(this),
            hookData: ZERO_BYTES
        });

        // seed some liquidity so we can move the price
        modifyLiquidityRouter.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: TickMath.minUsableTick(key.tickSpacing),
                tickUpper: TickMath.maxUsableTick(key.tickSpacing),
                liquidityDelta: 100_000e18
            }),
            ZERO_BYTES
        );

        // swap to move the price
        swap(key, true, 1000e18, ZERO_BYTES);

        // will revert because amount0Min and amount1Min are very strict
        vm.expectRevert();
        lpm.mint(params);
    }

    function test_burn(int24 tickLower, int24 tickUpper, uint128 liquidityDelta) public {
        uint256 balance0Start = currency0.balanceOfSelf();
        uint256 balance1Start = currency1.balanceOfSelf();

        // create liquidity we can burn
        uint256 tokenId;
        (tokenId, tickLower, tickUpper, liquidityDelta,) =
            createFuzzyLiquidity(lpm, address(this), key, tickLower, tickUpper, liquidityDelta, ZERO_BYTES);
        LiquidityRange memory position = LiquidityRange({key: key, tickLower: tickLower, tickUpper: tickUpper});
        assertEq(tokenId, 1);
        assertEq(lpm.ownerOf(1), address(this));
        assertEq(lpm.liquidityOf(address(this), position.toId()), liquidityDelta);

        // burn liquidity
        uint256 balance0BeforeBurn = currency0.balanceOfSelf();
        uint256 balance1BeforeBurn = currency1.balanceOfSelf();
        BalanceDelta delta = lpm.burn(tokenId, address(this), ZERO_BYTES, false);
        assertEq(lpm.liquidityOf(address(this), position.toId()), 0);

        // TODO: slightly off by 1 bip (0.0001%)
        assertApproxEqRel(currency0.balanceOfSelf(), balance0BeforeBurn + uint256(int256(-delta.amount0())), 0.0001e18);
        assertApproxEqRel(currency1.balanceOfSelf(), balance1BeforeBurn + uint256(int256(-delta.amount1())), 0.0001e18);

        // OZ 721 will revert if the token does not exist
        vm.expectRevert();
        lpm.ownerOf(1);

        // no tokens were lost, TODO: fuzzer showing off by 1 sometimes
        assertApproxEqAbs(currency0.balanceOfSelf(), balance0Start, 1 wei);
        assertApproxEqAbs(currency1.balanceOfSelf(), balance1Start, 1 wei);
    }

    function test_increaseLiquidity() public {}

    function test_decreaseLiquidity(
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidityDelta,
        uint128 decreaseLiquidityDelta
    ) public {
        uint256 tokenId;
        (tokenId, tickLower, tickUpper, liquidityDelta,) =
            createFuzzyLiquidity(lpm, address(this), key, tickLower, tickUpper, liquidityDelta, ZERO_BYTES);
        vm.assume(0 < decreaseLiquidityDelta);
        vm.assume(decreaseLiquidityDelta <= liquidityDelta);

        LiquidityRange memory position = LiquidityRange({key: key, tickLower: tickLower, tickUpper: tickUpper});

        uint256 balance0Before = currency0.balanceOfSelf();
        uint256 balance1Before = currency1.balanceOfSelf();
        INonfungiblePositionManager.DecreaseLiquidityParams memory params = INonfungiblePositionManager
            .DecreaseLiquidityParams({
            tokenId: tokenId,
            liquidityDelta: decreaseLiquidityDelta,
            amount0Min: 0,
            amount1Min: 0,
            recipient: address(this),
            deadline: block.timestamp + 1
        });
        BalanceDelta delta = lpm.decreaseLiquidity(params, ZERO_BYTES, false);
        assertEq(lpm.liquidityOf(address(this), position.toId()), liquidityDelta - decreaseLiquidityDelta);

        assertEq(currency0.balanceOfSelf() - balance0Before, uint256(int256(-delta.amount0())));
        assertEq(currency1.balanceOfSelf() - balance1Before, uint256(int256(-delta.amount1())));
    }

    function test_decreaseLiquidity_collectFees(
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidityDelta,
        uint128 decreaseLiquidityDelta
    ) public {
        uint256 tokenId;
        liquidityDelta = uint128(bound(liquidityDelta, 100e18, 100_000e18)); // require nontrivial amount of liquidity
        (tokenId, tickLower, tickUpper, liquidityDelta,) =
            createFuzzyLiquidity(lpm, address(this), key, tickLower, tickUpper, liquidityDelta, ZERO_BYTES);
        vm.assume(tickLower < -60 && 60 < tickUpper); // require two-sided liquidity
        vm.assume(0 < decreaseLiquidityDelta);
        vm.assume(decreaseLiquidityDelta <= liquidityDelta);

        // swap to create fees
        uint256 swapAmount = 0.01e18;
        swap(key, false, int256(swapAmount), ZERO_BYTES);

        LiquidityRange memory position = LiquidityRange({key: key, tickLower: tickLower, tickUpper: tickUpper});

        uint256 balance0Before = currency0.balanceOfSelf();
        uint256 balance1Before = currency1.balanceOfSelf();
        INonfungiblePositionManager.DecreaseLiquidityParams memory params = INonfungiblePositionManager
            .DecreaseLiquidityParams({
            tokenId: tokenId,
            liquidityDelta: decreaseLiquidityDelta,
            amount0Min: 0,
            amount1Min: 0,
            recipient: address(this),
            deadline: block.timestamp + 1
        });
        BalanceDelta delta = lpm.decreaseLiquidity(params, ZERO_BYTES, false);
        assertEq(lpm.liquidityOf(address(this), position.toId()), liquidityDelta - decreaseLiquidityDelta, "GRR");

        // express key.fee as wad (i.e. 3000 = 0.003e18)
        uint256 feeWad = uint256(key.fee).mulDivDown(FixedPointMathLib.WAD, 1_000_000);

        assertEq(currency0.balanceOfSelf() - balance0Before, uint256(int256(-delta.amount0())), "boo");
        assertEq(currency1.balanceOfSelf() - balance1Before, uint256(int256(-delta.amount1())), "guh");
    }

    function test_mintTransferBurn(int24 tickLower, int24 tickUpper, uint256 amount0Desired, uint256 amount1Desired)
        public
    {
        (tickLower, tickUpper,) = createFuzzyLiquidityParams(key, tickLower, tickUpper, DEAD_VALUE);
        (amount0Desired, amount1Desired) =
            createFuzzyAmountDesired(key, tickLower, tickUpper, amount0Desired, amount1Desired);

        LiquidityRange memory range = LiquidityRange({key: key, tickLower: tickLower, tickUpper: tickUpper});

        uint256 balance0Before = currency0.balanceOfSelf();
        uint256 balance1Before = currency1.balanceOfSelf();
        INonfungiblePositionManager.MintParams memory params = INonfungiblePositionManager.MintParams({
            range: range,
            amount0Desired: amount0Desired,
            amount1Desired: amount1Desired,
            amount0Min: 0,
            amount1Min: 0,
            deadline: block.timestamp + 1,
            recipient: address(this),
            hookData: ZERO_BYTES
        });
        (uint256 tokenId, BalanceDelta delta) = lpm.mint(params);
        uint256 liquidity = lpm.liquidityOf(address(this), range.toId());

        // transfer to Alice
        lpm.transferFrom(address(this), alice, tokenId);

        assertEq(lpm.liquidityOf(address(this), range.toId()), 0);
        assertEq(lpm.ownerOf(tokenId), alice);
        assertEq(lpm.liquidityOf(alice, range.toId()), liquidity);

        // Alice can burn the token
        vm.prank(alice);
        lpm.burn(tokenId, address(this), ZERO_BYTES, false);

        // TODO: assert balances
    }

    function test_mintTransferCollect() public {}
    function test_mintTransferIncrease() public {}
    function test_mintTransferDecrease() public {}
}
