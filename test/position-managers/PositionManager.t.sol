// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FixedPointMathLib} from "solmate/src/utils/FixedPointMathLib.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {Position} from "@uniswap/v4-core/src/libraries/Position.sol";

import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {IPositionManager, Actions} from "../../src/interfaces/IPositionManager.sol";
import {PositionManager} from "../../src/PositionManager.sol";
import {PositionConfig} from "../../src/libraries/PositionConfig.sol";

import {LiquidityFuzzers} from "../shared/fuzz/LiquidityFuzzers.sol";
import {Planner} from "../shared/Planner.sol";
import {PosmTestSetup} from "../shared/PosmTestSetup.sol";
import {ReentrantToken} from "../mocks/ReentrantToken.sol";
import {ReentrancyLock} from "../../src/base/ReentrancyLock.sol";

contract PositionManagerTest is Test, PosmTestSetup, LiquidityFuzzers {
    using FixedPointMathLib for uint256;
    using CurrencyLibrary for Currency;
    using Planner for Planner.Plan;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    PoolId poolId;
    address alice = makeAddr("ALICE");

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();

        (key, poolId) = initPool(currency0, currency1, IHooks(address(0)), 3000, SQRT_PRICE_1_1, ZERO_BYTES);

        // Requires currency0 and currency1 to be set in base Deployers contract.
        deployAndApprovePosm(manager);
    }

    function test_modifyLiquidities_reverts_mismatchedLengths() public {
        Planner.Plan memory planner = Planner.init();
        planner = planner.add(Actions.MINT, abi.encode("test"));
        planner = planner.add(Actions.BURN, abi.encode("test"));

        bytes[] memory badParams = new bytes[](1);

        vm.expectRevert(IPositionManager.MismatchedLengths.selector);
        lpm.modifyLiquidities(abi.encode(planner.actions, badParams), block.timestamp + 1);
    }

    function test_modifyLiquidities_reverts_reentrancy() public {
        // Create a reentrant token and initialize the pool
        ReentrantToken reentrantToken = new ReentrantToken(lpm);
        (currency0, currency1) = (address(reentrantToken) < Currency.unwrap(currency1))
            ? (Currency.wrap(address(reentrantToken)), currency1)
            : (currency1, Currency.wrap(address(reentrantToken)));

        (key, poolId) = initPool(currency0, currency1, IHooks(address(0)), 3000, SQRT_PRICE_1_1, ZERO_BYTES);

        // Try to add liquidity at that range, but the token reenters posm
        PositionConfig memory config = PositionConfig({poolKey: key, tickLower: 0, tickUpper: 60});
        bytes memory calls = getMintEncoded(config, 1e18, address(this), "");

        // SafeTransferLib does not bubble the ContractLocked error and instead reverts with its own error
        vm.expectRevert("TRANSFER_FROM_FAILED");
        lpm.modifyLiquidities(calls, block.timestamp + 1);
    }

    function test_fuzz_mint_withLiquidityDelta(IPoolManager.ModifyLiquidityParams memory params, uint160 sqrtPriceX96)
        public
    {
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
        BalanceDelta delta = mint(config, liquidityToAdd, address(this), ZERO_BYTES);

        assertEq(tokenId, 1);
        assertEq(lpm.nextTokenId(), 2);
        assertEq(lpm.ownerOf(tokenId), address(this));

        bytes32 positionId =
            Position.calculatePositionKey(address(lpm), config.tickLower, config.tickUpper, bytes32(tokenId));
        (uint256 liquidity,,) = manager.getPositionInfo(config.poolKey.toId(), positionId);

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
        BalanceDelta delta = mint(config, liquidityToAdd, address(this), ZERO_BYTES);

        uint256 balance0After = currency0.balanceOfSelf();
        uint256 balance1After = currency1.balanceOfSelf();

        assertEq(tokenId, 1);
        assertEq(lpm.ownerOf(1), address(this));

        assertEq(uint256(int256(-delta.amount0())), amount0Desired);
        assertEq(uint256(int256(-delta.amount1())), amount1Desired);
        assertEq(balance0Before - balance0After, uint256(int256(-delta.amount0())));
        assertEq(balance1Before - balance1After, uint256(int256(-delta.amount1())));
    }

    function test_fuzz_mint_recipient(IPoolManager.ModifyLiquidityParams memory seedParams) public {
        IPoolManager.ModifyLiquidityParams memory params = createFuzzyLiquidityParams(key, seedParams, SQRT_PRICE_1_1);
        uint256 liquidityToAdd =
            params.liquidityDelta < 0 ? uint256(-params.liquidityDelta) : uint256(params.liquidityDelta);

        PositionConfig memory config =
            PositionConfig({poolKey: key, tickLower: params.tickLower, tickUpper: params.tickUpper});

        uint256 tokenId = lpm.nextTokenId();
        uint256 balance0Before = currency0.balanceOfSelf();
        uint256 balance1Before = currency1.balanceOfSelf();
        uint256 balance0BeforeAlice = currency0.balanceOf(alice);
        uint256 balance1BeforeAlice = currency1.balanceOf(alice);
        BalanceDelta delta = mint(config, liquidityToAdd, alice, ZERO_BYTES);

        assertEq(tokenId, 1);
        assertEq(lpm.ownerOf(tokenId), alice);

        // alice was not the payer
        assertEq(balance0Before - currency0.balanceOfSelf(), uint256(int256(-delta.amount0())));
        assertEq(balance1Before - currency1.balanceOfSelf(), uint256(int256(-delta.amount1())));
        assertEq(currency0.balanceOf(alice), balance0BeforeAlice);
        assertEq(currency1.balanceOf(alice), balance1BeforeAlice);
    }

    function test_fuzz_burn_emptyPosition(IPoolManager.ModifyLiquidityParams memory params) public {
        uint256 balance0Start = currency0.balanceOfSelf();
        uint256 balance1Start = currency1.balanceOfSelf();

        // create liquidity we can burn
        uint256 tokenId;
        (tokenId, params) = addFuzzyLiquidity(lpm, address(this), key, params, SQRT_PRICE_1_1, ZERO_BYTES);
        PositionConfig memory config =
            PositionConfig({poolKey: key, tickLower: params.tickLower, tickUpper: params.tickUpper});
        assertEq(tokenId, 1);
        assertEq(lpm.ownerOf(1), address(this));

        bytes32 positionId =
            Position.calculatePositionKey(address(lpm), config.tickLower, config.tickUpper, bytes32(tokenId));
        (uint256 liquidity,,) = manager.getPositionInfo(config.poolKey.toId(), positionId);

        assertEq(liquidity, uint256(params.liquidityDelta));

        // burn liquidity
        uint256 balance0BeforeBurn = currency0.balanceOfSelf();
        uint256 balance1BeforeBurn = currency1.balanceOfSelf();

        BalanceDelta deltaDecrease = decreaseLiquidity(tokenId, config, liquidity, ZERO_BYTES);
        // No decrease will happen on the burn call so the delta will be 0.
        (BalanceDelta delta) = burn(tokenId, config, ZERO_BYTES);
        assertEq(delta.amount0(), 0);
        assertEq(delta.amount1(), 0);

        (liquidity,,) = manager.getPositionInfo(config.poolKey.toId(), positionId);

        assertEq(liquidity, 0);

        assertEq(currency0.balanceOfSelf(), balance0BeforeBurn + uint256(int256(deltaDecrease.amount0())));
        assertEq(currency1.balanceOfSelf(), balance1BeforeBurn + uint256(uint128(deltaDecrease.amount1())));

        // OZ 721 will revert if the token does not exist
        vm.expectRevert();
        lpm.ownerOf(1);

        // no tokens were lost, TODO: fuzzer showing off by 1 sometimes
        // Potentially because we round down in core. I believe this is known in V3. But let's check!
        assertApproxEqAbs(currency0.balanceOfSelf(), balance0Start, 1 wei);
        assertApproxEqAbs(currency1.balanceOfSelf(), balance1Start, 1 wei);
    }

    function test_fuzz_burn_nonEmptyPosition(IPoolManager.ModifyLiquidityParams memory params) public {
        uint256 balance0Start = currency0.balanceOfSelf();
        uint256 balance1Start = currency1.balanceOfSelf();

        // create liquidity we can burn
        uint256 tokenId;
        (tokenId, params) = addFuzzyLiquidity(lpm, address(this), key, params, SQRT_PRICE_1_1, ZERO_BYTES);
        PositionConfig memory config =
            PositionConfig({poolKey: key, tickLower: params.tickLower, tickUpper: params.tickUpper});
        assertEq(tokenId, 1);
        assertEq(lpm.ownerOf(1), address(this));

        bytes32 positionId =
            Position.calculatePositionKey(address(lpm), config.tickLower, config.tickUpper, bytes32(tokenId));
        (uint256 liquidity,,) = manager.getPositionInfo(config.poolKey.toId(), positionId);

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

        BalanceDelta deltaBurn = burn(tokenId, config, ZERO_BYTES);
        assertEq(uint256(int256(deltaBurn.amount0())), amount0);
        assertEq(uint256(int256(deltaBurn.amount1())), amount1);

        (liquidity,,) = manager.getPositionInfo(config.poolKey.toId(), positionId);

        assertEq(liquidity, 0);

        assertEq(currency0.balanceOfSelf(), balance0BeforeBurn + uint256(int256(deltaBurn.amount0())));
        assertEq(currency1.balanceOfSelf(), balance1BeforeBurn + uint256(uint128(deltaBurn.amount1())));

        // OZ 721 will revert if the token does not exist
        vm.expectRevert();
        lpm.ownerOf(1);

        // no tokens were lost, TODO: fuzzer showing off by 1 sometimes
        // Potentially because we round down in core. I believe this is known in V3. But let's check!
        assertApproxEqAbs(currency0.balanceOfSelf(), balance0Start, 1 wei);
        assertApproxEqAbs(currency1.balanceOfSelf(), balance1Start, 1 wei);
    }

    function test_fuzz_decreaseLiquidity(
        IPoolManager.ModifyLiquidityParams memory params,
        uint256 decreaseLiquidityDelta
    ) public {
        uint256 tokenId;
        (tokenId, params) = addFuzzyLiquidity(lpm, address(this), key, params, SQRT_PRICE_1_1, ZERO_BYTES);
        decreaseLiquidityDelta = uint256(bound(int256(decreaseLiquidityDelta), 0, params.liquidityDelta));

        PositionConfig memory config =
            PositionConfig({poolKey: key, tickLower: params.tickLower, tickUpper: params.tickUpper});

        decreaseLiquidity(tokenId, config, decreaseLiquidityDelta, ZERO_BYTES);

        bytes32 positionId =
            Position.calculatePositionKey(address(lpm), config.tickLower, config.tickUpper, bytes32(tokenId));
        (uint256 liquidity,,) = manager.getPositionInfo(config.poolKey.toId(), positionId);

        assertEq(liquidity, uint256(params.liquidityDelta) - decreaseLiquidityDelta);
    }

    function test_fuzz_decreaseLiquidity_assertCollectedBalance(
        IPoolManager.ModifyLiquidityParams memory params,
        uint256 decreaseLiquidityDelta
    ) public {
        uint256 tokenId;
        (tokenId, params) = addFuzzyLiquidity(lpm, address(this), key, params, SQRT_PRICE_1_1, ZERO_BYTES);
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
        BalanceDelta delta = decreaseLiquidity(tokenId, config, decreaseLiquidityDelta, ZERO_BYTES);

        bytes32 positionId =
            Position.calculatePositionKey(address(lpm), config.tickLower, config.tickUpper, bytes32(tokenId));
        (uint256 liquidity,,) = manager.getPositionInfo(config.poolKey.toId(), positionId);

        assertEq(liquidity, uint256(params.liquidityDelta) - decreaseLiquidityDelta);

        // The change in balance equals the delta returned.
        assertEq(currency0.balanceOfSelf() - balance0Before, uint256(int256(delta.amount0())));
        assertEq(currency1.balanceOfSelf() - balance1Before, uint256(int256(delta.amount1())));
    }

    function test_initialize() public {
        // initialize a new pool and add liquidity
        key = PoolKey({currency0: currency0, currency1: currency1, fee: 0, tickSpacing: 10, hooks: IHooks(address(0))});
        lpm.initializePool(key, SQRT_PRICE_1_1, ZERO_BYTES);

        (uint160 sqrtPriceX96, int24 tick, uint24 protocolFee, uint24 lpFee) = manager.getSlot0(key.toId());
        assertEq(sqrtPriceX96, SQRT_PRICE_1_1);
        assertEq(tick, 0);
        assertEq(protocolFee, 0);
        assertEq(lpFee, key.fee);
    }

    function test_initialize_fuzz() public {}
    function test_mintTransferBurn() public {}
    function test_mintTransferCollect() public {}
    function test_mintTransferIncrease() public {}
    function test_mintTransferDecrease() public {}
    function test_mint_slippageRevert() public {}
}
