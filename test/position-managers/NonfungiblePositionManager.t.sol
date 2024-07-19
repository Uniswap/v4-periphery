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
    uint256 constant STARTING_USER_BALANCE = 10_000_000 ether;

    function setUp() public {
        Deployers.deployFreshManagerAndRouters();
        Deployers.deployMintAndApprove2Currencies();

        (key, poolId) = initPool(currency0, currency1, IHooks(address(0)), 3000, SQRT_PRICE_1_1, ZERO_BYTES);

        lpm = new NonfungiblePositionManager(manager);

        IERC20(Currency.unwrap(currency0)).approve(address(lpm), type(uint256).max);
        IERC20(Currency.unwrap(currency1)).approve(address(lpm), type(uint256).max);

        // Give tokens to Alice and Bob, with approvals
        IERC20(Currency.unwrap(currency0)).transfer(alice, STARTING_USER_BALANCE);
        IERC20(Currency.unwrap(currency1)).transfer(alice, STARTING_USER_BALANCE);
        vm.startPrank(alice);
        IERC20(Currency.unwrap(currency0)).approve(address(lpm), type(uint256).max);
        IERC20(Currency.unwrap(currency1)).approve(address(lpm), type(uint256).max);
        vm.stopPrank();
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
    //         deadline:
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

        uint256 balance0Before = currency0.balanceOfSelf();
        uint256 balance1Before = currency1.balanceOfSelf();
        BalanceDelta delta = _decreaseLiquidity(tokenId, decreaseLiquidityDelta, ZERO_BYTES);

        bytes32 positionId =
            keccak256(abi.encodePacked(address(lpm), range.tickLower, range.tickUpper, bytes32(tokenId)));
        (uint256 liquidity,,) = manager.getPositionInfo(range.poolKey.toId(), positionId);
        assertEq(liquidity, uint256(params.liquidityDelta) - decreaseLiquidityDelta);

        assertEq(currency0.balanceOfSelf() - balance0Before, uint128(delta.amount0()));
        assertEq(currency1.balanceOfSelf() - balance1Before, uint128(delta.amount1()));
    }

    function test_decreaseLiquidity_collectFees(
        IPoolManager.ModifyLiquidityParams memory params,
        uint256 decreaseLiquidityDelta
    ) public {
        uint256 tokenId;
        (tokenId, params) = createFuzzyLiquidity(lpm, address(this), key, params, SQRT_PRICE_1_1, ZERO_BYTES);
        vm.assume(params.tickLower < 0 && 0 < params.tickUpper); // require two-sided liquidity
        decreaseLiquidityDelta = bound(decreaseLiquidityDelta, 1, uint256(params.liquidityDelta));

        LiquidityRange memory range =
            LiquidityRange({poolKey: key, tickLower: params.tickLower, tickUpper: params.tickUpper});

        // donate to generate fee revenue
        uint256 feeRevenue0 = 1e18;
        uint256 feeRevenue1 = 0.1e18;
        donateRouter.donate(key, feeRevenue0, feeRevenue1, ZERO_BYTES);

        uint256 balance0Before = currency0.balanceOfSelf();
        uint256 balance1Before = currency1.balanceOfSelf();
        _decreaseLiquidity(tokenId, decreaseLiquidityDelta, ZERO_BYTES);

        bytes32 positionId =
            keccak256(abi.encodePacked(address(lpm), range.tickLower, range.tickUpper, bytes32(tokenId)));
        (uint256 liquidity,,) = manager.getPositionInfo(range.poolKey.toId(), positionId);
        assertEq(liquidity, uint256(params.liquidityDelta) - decreaseLiquidityDelta);

        (uint256 amount0, uint256 amount1) = LiquidityAmounts.getAmountsForLiquidity(
            SQRT_PRICE_1_1,
            TickMath.getSqrtPriceAtTick(range.tickLower),
            TickMath.getSqrtPriceAtTick(range.tickUpper),
            uint128(decreaseLiquidityDelta)
        );

        // claimed both principal liquidity and fee revenue
        assertApproxEqAbs(currency0.balanceOfSelf() - balance0Before, amount0 + feeRevenue0, 1 wei);
        assertApproxEqAbs(currency1.balanceOfSelf() - balance1Before, amount1 + feeRevenue1, 1 wei);
    }

    function test_mintTransferBurn() public {
        LiquidityRange memory range = LiquidityRange({poolKey: key, tickLower: -600, tickUpper: 600});
        uint256 liquidity = 100e18;
        BalanceDelta mintDelta = _mint(range, liquidity, address(this), ZERO_BYTES);
        uint256 tokenId = lpm.nextTokenId() - 1;

        // transfer to alice
        lpm.transferFrom(address(this), alice, tokenId);

        // alice can decrease liquidity and burn
        Planner.Plan memory planner = Planner.init();
        planner = planner.add(Actions.DECREASE, abi.encode(tokenId, liquidity, ZERO_BYTES));
        planner = planner.add(Actions.BURN, abi.encode(tokenId));
        planner = planner.finalize(range.poolKey);
        bytes memory calls = planner.zip();

        uint256 balance0BeforeAlice = currency0.balanceOf(alice);
        uint256 balance1BeforeAlice = currency0.balanceOf(alice);

        vm.prank(alice);
        lpm.modifyLiquidities(calls, _deadline);

        // token was burned and does not exist anymore
        vm.expectRevert();
        lpm.ownerOf(tokenId);

        // alice received the principal liquidity
        assertApproxEqAbs(currency0.balanceOf(alice) - balance0BeforeAlice, uint128(-mintDelta.amount0()), 1 wei);
        assertApproxEqAbs(currency1.balanceOf(alice) - balance1BeforeAlice, uint128(-mintDelta.amount1()), 1 wei);
    }

    function test_mintTransferCollect() public {
        LiquidityRange memory range = LiquidityRange({poolKey: key, tickLower: -600, tickUpper: 600});
        uint256 liquidity = 100e18;
        _mint(range, liquidity, address(this), ZERO_BYTES);
        uint256 tokenId = lpm.nextTokenId() - 1;

        // donate to generate fee revenue
        uint256 feeRevenue0 = 1e18;
        uint256 feeRevenue1 = 0.1e18;
        donateRouter.donate(key, feeRevenue0, feeRevenue1, ZERO_BYTES);

        // transfer to alice
        lpm.transferFrom(address(this), alice, tokenId);

        // alice can collect the fees
        uint256 balance0BeforeAlice = currency0.balanceOf(alice);
        uint256 balance1BeforeAlice = currency1.balanceOf(alice);
        vm.startPrank(alice);
        BalanceDelta delta = _collect(tokenId, alice, ZERO_BYTES);
        vm.stopPrank();

        // alice received the fee revenue
        assertApproxEqAbs(currency0.balanceOf(alice) - balance0BeforeAlice, feeRevenue0, 1 wei);
        assertApproxEqAbs(currency1.balanceOf(alice) - balance1BeforeAlice, feeRevenue1, 1 wei);
        assertApproxEqAbs(uint128(delta.amount0()), feeRevenue0, 1 wei);
        assertApproxEqAbs(uint128(delta.amount1()), feeRevenue1, 1 wei);
    }

    function test_mintTransferIncrease() public {
        LiquidityRange memory range = LiquidityRange({poolKey: key, tickLower: -600, tickUpper: 600});
        uint256 liquidity = 100e18;
        _mint(range, liquidity, address(this), ZERO_BYTES);
        uint256 tokenId = lpm.nextTokenId() - 1;

        // transfer to alice
        lpm.transferFrom(address(this), alice, tokenId);

        // alice increases liquidity and is the payer
        uint256 balance0BeforeAlice = currency0.balanceOf(alice);
        uint256 balance1BeforeAlice = currency1.balanceOf(alice);
        vm.startPrank(alice);
        uint256 liquidityToAdd = 10e18;
        BalanceDelta delta = _increaseLiquidity(tokenId, liquidityToAdd, ZERO_BYTES);
        vm.stopPrank();

        // position liquidity increased
        bytes32 positionId =
            keccak256(abi.encodePacked(address(lpm), range.tickLower, range.tickUpper, bytes32(tokenId)));
        (uint256 newLiq,,) = manager.getPositionInfo(range.poolKey.toId(), positionId);
        assertEq(newLiq, liquidity + liquidityToAdd);

        // alice paid the tokens
        (uint256 amount0, uint256 amount1) = LiquidityAmounts.getAmountsForLiquidity(
            SQRT_PRICE_1_1,
            TickMath.getSqrtPriceAtTick(range.tickLower),
            TickMath.getSqrtPriceAtTick(range.tickUpper),
            uint128(liquidityToAdd)
        );
        assertApproxEqAbs(balance0BeforeAlice - currency0.balanceOf(alice), amount0, 1 wei);
        assertApproxEqAbs(balance1BeforeAlice - currency1.balanceOf(alice), amount1, 1 wei);
        assertApproxEqAbs(uint128(-delta.amount0()), amount0, 1 wei);
        assertApproxEqAbs(uint128(-delta.amount1()), amount1, 1 wei);
    }

    function test_mintTransferDecrease() public {
        LiquidityRange memory range = LiquidityRange({poolKey: key, tickLower: -600, tickUpper: 600});
        uint256 liquidity = 100e18;
        _mint(range, liquidity, address(this), ZERO_BYTES);
        uint256 tokenId = lpm.nextTokenId() - 1;

        // donate to generate fee revenue
        uint256 feeRevenue0 = 1e18;
        uint256 feeRevenue1 = 0.1e18;
        donateRouter.donate(key, feeRevenue0, feeRevenue1, ZERO_BYTES);

        // transfer to alice
        lpm.transferFrom(address(this), alice, tokenId);

        {
            // alice decreases liquidity and is the recipient
            uint256 balance0BeforeAlice = currency0.balanceOf(alice);
            uint256 balance1BeforeAlice = currency1.balanceOf(alice);
            vm.startPrank(alice);
            uint256 liquidityToRemove = 10e18;
            BalanceDelta delta = _decreaseLiquidity(tokenId, liquidityToRemove, ZERO_BYTES);
            vm.stopPrank();

            {
                // position liquidity decreased
                bytes32 positionId =
                    keccak256(abi.encodePacked(address(lpm), range.tickLower, range.tickUpper, bytes32(tokenId)));
                (uint256 newLiq,,) = manager.getPositionInfo(range.poolKey.toId(), positionId);
                assertEq(newLiq, liquidity - liquidityToRemove);
            }

            // alice received the principal + fees
            (uint256 amount0, uint256 amount1) = LiquidityAmounts.getAmountsForLiquidity(
                SQRT_PRICE_1_1,
                TickMath.getSqrtPriceAtTick(range.tickLower),
                TickMath.getSqrtPriceAtTick(range.tickUpper),
                uint128(liquidityToRemove)
            );
            assertApproxEqAbs(currency0.balanceOf(alice) - balance0BeforeAlice, amount0 + feeRevenue0, 1 wei);
            assertApproxEqAbs(currency1.balanceOf(alice) - balance1BeforeAlice, amount1 + feeRevenue1, 1 wei);
            assertApproxEqAbs(uint128(delta.amount0()), amount0 + feeRevenue0, 1 wei);
            assertApproxEqAbs(uint128(delta.amount1()), amount1 + feeRevenue1, 1 wei);
        }
    }

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
