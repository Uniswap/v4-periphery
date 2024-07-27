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
import {FixedPointMathLib} from "solmate/src/utils/FixedPointMathLib.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {Position} from "@uniswap/v4-core/src/libraries/Position.sol";

import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {IPositionManager, Actions} from "../../src/interfaces/IPositionManager.sol";
import {PositionManager} from "../../src/PositionManager.sol";
import {PositionConfig} from "../../src/libraries/PositionConfig.sol";

import {LiquidityFuzzers} from "../shared/fuzz/LiquidityFuzzers.sol";
import {Planner} from "../shared/Planner.sol";
import {PosmTestSetup} from "../shared/PosmTestSetup.sol";

contract ExecuteTest is Test, PosmTestSetup, LiquidityFuzzers {
    using FixedPointMathLib for uint256;
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;
    using Planner for Planner.Plan;
    using StateLibrary for IPoolManager;

    PoolId poolId;
    address alice = makeAddr("ALICE");
    address bob = makeAddr("BOB");

    PositionConfig config;

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();

        (key, poolId) = initPool(currency0, currency1, IHooks(address(0)), 3000, SQRT_PRICE_1_1, ZERO_BYTES);

        // Requires currency0 and currency1 to be set in base Deployers contract.
        deployAndApprovePosm(manager);

        // Give tokens to Alice and Bob.
        seedBalance(alice);
        seedBalance(bob);

        // Approve posm for Alice and bob.
        approvePosmFor(alice);
        approvePosmFor(bob);

        // define a reusable pool position
        config = PositionConfig({poolKey: key, tickLower: -300, tickUpper: 300});
    }

    function test_fuzz_execute_increaseLiquidity_once(uint256 initialLiquidity, uint256 liquidityToAdd) public {
        initialLiquidity = bound(initialLiquidity, 1e18, 1000e18);
        liquidityToAdd = bound(liquidityToAdd, 1e18, 1000e18);
        mint(config, initialLiquidity, address(this), ZERO_BYTES);
        uint256 tokenId = lpm.nextTokenId() - 1;

        increaseLiquidity(tokenId, config, liquidityToAdd, ZERO_BYTES);

        bytes32 positionId =
            Position.calculatePositionKey(address(lpm), config.tickLower, config.tickUpper, bytes32(tokenId));
        (uint256 liquidity,,) = manager.getPositionInfo(config.poolKey.toId(), positionId);

        assertEq(liquidity, initialLiquidity + liquidityToAdd);
    }

    function test_fuzz_execute_increaseLiquidity_twice(
        uint256 initialLiquidity,
        uint256 liquidityToAdd,
        uint256 liquidityToAdd2
    ) public {
        initialLiquidity = bound(initialLiquidity, 1e18, 1000e18);
        liquidityToAdd = bound(liquidityToAdd, 1e18, 1000e18);
        liquidityToAdd2 = bound(liquidityToAdd2, 1e18, 1000e18);
        mint(config, initialLiquidity, address(this), ZERO_BYTES);
        uint256 tokenId = lpm.nextTokenId() - 1;

        Planner.Plan memory planner = Planner.init();

        planner = planner.add(Actions.INCREASE, abi.encode(tokenId, config, liquidityToAdd, ZERO_BYTES));
        planner = planner.add(Actions.INCREASE, abi.encode(tokenId, config, liquidityToAdd2, ZERO_BYTES));

        bytes memory calls = planner.finalize(config.poolKey);
        lpm.modifyLiquidities(calls, _deadline);

        bytes32 positionId =
            Position.calculatePositionKey(address(lpm), config.tickLower, config.tickUpper, bytes32(tokenId));
        (uint256 liquidity,,) = manager.getPositionInfo(config.poolKey.toId(), positionId);

        assertEq(liquidity, initialLiquidity + liquidityToAdd + liquidityToAdd2);
    }

    // this case doesnt make sense in real world usage, so it doesnt have a cool name. but its a good test case
    function test_fuzz_execute_mintAndIncrease(uint256 initialLiquidity, uint256 liquidityToAdd) public {
        initialLiquidity = bound(initialLiquidity, 1e18, 1000e18);
        liquidityToAdd = bound(liquidityToAdd, 1e18, 1000e18);

        uint256 tokenId = lpm.nextTokenId(); // assume that the .mint() produces tokenId=1, to be used in increaseLiquidity

        Planner.Plan memory planner = Planner.init();

        planner = planner.add(Actions.MINT, abi.encode(config, initialLiquidity, address(this), ZERO_BYTES));
        planner = planner.add(Actions.INCREASE, abi.encode(tokenId, config, liquidityToAdd, ZERO_BYTES));

        bytes memory calls = planner.finalize(config.poolKey);
        lpm.modifyLiquidities(calls, _deadline);

        bytes32 positionId =
            Position.calculatePositionKey(address(lpm), config.tickLower, config.tickUpper, bytes32(tokenId));
        (uint256 liquidity,,) = manager.getPositionInfo(config.poolKey.toId(), positionId);

        assertEq(liquidity, initialLiquidity + liquidityToAdd);
    }

    // rebalance: burn and mint
    function test_execute_rebalance_perfect() public {
        uint256 initialLiquidity = 100e18;

        // mint a position on range [-300, 300]
        BalanceDelta delta = mint(config, initialLiquidity, address(this), ZERO_BYTES);
        uint256 tokenId = lpm.nextTokenId() - 1;

        // we'll burn and mint a new position on [-60, 60]; calculate the liquidity units for the new range
        PositionConfig memory newConfig = PositionConfig({poolKey: config.poolKey, tickLower: -60, tickUpper: 60});
        uint128 newLiquidity = LiquidityAmounts.getLiquidityForAmounts(
            SQRT_PRICE_1_1,
            TickMath.getSqrtPriceAtTick(newConfig.tickLower),
            TickMath.getSqrtPriceAtTick(newConfig.tickUpper),
            uint128(-delta.amount0()),
            uint128(-delta.amount1())
        );

        uint256 balance0Before = currency0.balanceOfSelf();
        uint256 balance1Before = currency1.balanceOfSelf();

        Planner.Plan memory planner = Planner.init();
        planner = planner.add(Actions.BURN, abi.encode(tokenId, config, ZERO_BYTES));
        planner = planner.add(Actions.MINT, abi.encode(newConfig, newLiquidity, address(this), ZERO_BYTES));
        bytes memory calls = planner.finalize(config.poolKey);

        bytes[] memory data = lpm.modifyLiquidities(calls, _deadline);
        int256 delta0 = abi.decode(data[data.length - 2], (int256));
        int256 delta1 = abi.decode(data[data.length - 1], (int256));

        uint256 balance0After = currency0.balanceOfSelf();
        uint256 balance1After = currency1.balanceOfSelf();

        // TODO: use clear so user does not pay 1 wei
        assertApproxEqAbs(delta0, 0, 1 wei);
        assertApproxEqAbs(delta1, 0, 1 wei);
        assertApproxEqAbs(balance0Before - balance0After, 0, 1 wei);
        assertApproxEqAbs(balance1Before - balance1After, 0, 1 wei);

        // old position was burned
        vm.expectRevert();
        lpm.ownerOf(tokenId);

        // old position has no liquidity
        bytes32 positionId =
            keccak256(abi.encodePacked(address(lpm), config.tickLower, config.tickUpper, bytes32(tokenId)));
        uint128 liquidity = manager.getPositionLiquidity(config.poolKey.toId(), positionId);
        assertEq(liquidity, 0);

        // new token was minted
        uint256 newTokenId = lpm.nextTokenId() - 1;
        assertEq(lpm.ownerOf(newTokenId), address(this));

        // new token has expected liquidity
        positionId =
            keccak256(abi.encodePacked(address(lpm), newConfig.tickLower, newConfig.tickUpper, bytes32(newTokenId)));
        liquidity = manager.getPositionLiquidity(config.poolKey.toId(), positionId);
        assertEq(liquidity, newLiquidity);
    }

    // coalesce: burn and increase
    function test_execute_coalesce() public {}
    // split: decrease and mint
    function test_execute_split() public {}
    // shift: decrease and increase
    function test_execute_shift() public {}
    // shard: collect and mint
    function test_execute_shard() public {}
    // feed: collect and increase
    function test_execute_feed() public {}

    // transplant: burn and mint on different keys
    function test_execute_transplant() public {}
    // cross-coalesce: burn and increase on different keys
    function test_execute_crossCoalesce() public {}
    // cross-split: decrease and mint on different keys
    function test_execute_crossSplit() public {}
    // cross-shift: decrease and increase on different keys
    function test_execute_crossShift() public {}
    // cross-shard: collect and mint on different keys
    function test_execute_crossShard() public {}
    // cross-feed: collect and increase on different keys
    function test_execute_crossFeed() public {}
}
