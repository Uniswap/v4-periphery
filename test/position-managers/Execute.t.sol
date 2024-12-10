// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {FixedPointMathLib} from "solmate/src/utils/FixedPointMathLib.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {Position} from "@uniswap/v4-core/src/libraries/Position.sol";

import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {IERC721} from "forge-std/interfaces/IERC721.sol";

import {IPositionManager} from "../../src/interfaces/IPositionManager.sol";
import {PositionConfig} from "../shared/PositionConfig.sol";
import {ActionConstants} from "../../src/libraries/ActionConstants.sol";
import {Actions} from "../../src/libraries/Actions.sol";

import {LiquidityFuzzers} from "../shared/fuzz/LiquidityFuzzers.sol";
import {Planner, Plan} from "../shared/Planner.sol";
import {PosmTestSetup} from "../shared/PosmTestSetup.sol";

contract ExecuteTest is Test, PosmTestSetup, LiquidityFuzzers {
    using FixedPointMathLib for uint256;
    using StateLibrary for IPoolManager;

    PoolId poolId;
    address alice = makeAddr("ALICE");
    address bob = makeAddr("BOB");

    PositionConfig config;

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();

        // This is needed to receive return deltas from modifyLiquidity calls.
        deployPosmHookSavesDelta();

        (key, poolId) = initPool(currency0, currency1, IHooks(address(hook)), 3000, SQRT_PRICE_1_1);

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
        uint256 tokenId = lpm.nextTokenId();
        mint(config, initialLiquidity, ActionConstants.MSG_SENDER, ZERO_BYTES);

        increaseLiquidity(tokenId, config, liquidityToAdd, ZERO_BYTES);

        uint256 liquidity = lpm.getPositionLiquidity(tokenId);

        assertEq(liquidity, initialLiquidity + liquidityToAdd);
    }

    function test_fuzz_execute_increaseLiquidity_twice_withClose(
        uint256 initialLiquidity,
        uint256 liquidityToAdd,
        uint256 liquidityToAdd2
    ) public {
        initialLiquidity = bound(initialLiquidity, 1e18, 1000e18);
        liquidityToAdd = bound(liquidityToAdd, 1e18, 1000e18);
        liquidityToAdd2 = bound(liquidityToAdd2, 1e18, 1000e18);
        uint256 tokenId = lpm.nextTokenId();
        mint(config, initialLiquidity, ActionConstants.MSG_SENDER, ZERO_BYTES);

        Plan memory planner = Planner.init();

        planner.add(
            Actions.INCREASE_LIQUIDITY,
            abi.encode(tokenId, liquidityToAdd, MAX_SLIPPAGE_INCREASE, MAX_SLIPPAGE_INCREASE, ZERO_BYTES)
        );
        planner.add(
            Actions.INCREASE_LIQUIDITY,
            abi.encode(tokenId, liquidityToAdd2, MAX_SLIPPAGE_INCREASE, MAX_SLIPPAGE_INCREASE, ZERO_BYTES)
        );

        bytes memory calls = planner.finalizeModifyLiquidityWithClose(config.poolKey);
        lpm.modifyLiquidities(calls, _deadline);

        uint256 liquidity = lpm.getPositionLiquidity(tokenId);

        assertEq(liquidity, initialLiquidity + liquidityToAdd + liquidityToAdd2);
    }

    function test_fuzz_execute_increaseLiquidity_twice_withSettlePair(
        uint256 initialLiquidity,
        uint256 liquidityToAdd,
        uint256 liquidityToAdd2
    ) public {
        initialLiquidity = bound(initialLiquidity, 1e18, 1000e18);
        liquidityToAdd = bound(liquidityToAdd, 1e18, 1000e18);
        liquidityToAdd2 = bound(liquidityToAdd2, 1e18, 1000e18);
        uint256 tokenId = lpm.nextTokenId();
        mint(config, initialLiquidity, address(this), ZERO_BYTES);

        Plan memory planner = Planner.init();

        planner.add(
            Actions.INCREASE_LIQUIDITY,
            abi.encode(tokenId, liquidityToAdd, MAX_SLIPPAGE_INCREASE, MAX_SLIPPAGE_INCREASE, ZERO_BYTES)
        );
        planner.add(
            Actions.INCREASE_LIQUIDITY,
            abi.encode(tokenId, liquidityToAdd2, MAX_SLIPPAGE_INCREASE, MAX_SLIPPAGE_INCREASE, ZERO_BYTES)
        );

        bytes memory calls = planner.finalizeModifyLiquidityWithSettlePair(config.poolKey);
        lpm.modifyLiquidities(calls, _deadline);

        uint256 liquidity = lpm.getPositionLiquidity(tokenId);

        assertEq(liquidity, initialLiquidity + liquidityToAdd + liquidityToAdd2);
    }

    // this case doesnt make sense in real world usage, so it doesnt have a cool name. but its a good test case
    function test_fuzz_execute_mintAndIncrease(uint256 initialLiquidity, uint256 liquidityToAdd) public {
        initialLiquidity = bound(initialLiquidity, 1e18, 1000e18);
        liquidityToAdd = bound(liquidityToAdd, 1e18, 1000e18);

        uint256 tokenId = lpm.nextTokenId(); // assume that the .mint() produces tokenId=1, to be used in increaseLiquidity

        Plan memory planner = Planner.init();

        planner.add(
            Actions.MINT_POSITION,
            abi.encode(
                config.poolKey,
                config.tickLower,
                config.tickUpper,
                initialLiquidity,
                MAX_SLIPPAGE_INCREASE,
                MAX_SLIPPAGE_INCREASE,
                ActionConstants.MSG_SENDER,
                ZERO_BYTES
            )
        );
        planner.add(
            Actions.INCREASE_LIQUIDITY,
            abi.encode(tokenId, liquidityToAdd, MAX_SLIPPAGE_INCREASE, MAX_SLIPPAGE_INCREASE, ZERO_BYTES)
        );

        bytes memory calls = planner.finalizeModifyLiquidityWithClose(config.poolKey);
        lpm.modifyLiquidities(calls, _deadline);

        uint256 liquidity = lpm.getPositionLiquidity(tokenId);

        assertEq(liquidity, initialLiquidity + liquidityToAdd);
    }

    // rebalance: burn and mint
    function test_execute_rebalance_perfect() public {
        uint256 initialLiquidity = 100e18;

        // mint a position on range [-300, 300]
        uint256 tokenId = lpm.nextTokenId();
        mint(config, initialLiquidity, ActionConstants.MSG_SENDER, ZERO_BYTES);
        BalanceDelta delta = getLastDelta();

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

        hook.clearDeltas(); // clear the delta so that we can check the net delta for BURN & MINT

        Plan memory planner = Planner.init();
        planner.add(
            Actions.BURN_POSITION,
            abi.encode(tokenId, uint128(-delta.amount0()) - 1 wei, uint128(-delta.amount1()) - 1 wei, ZERO_BYTES)
        );
        planner.add(
            Actions.MINT_POSITION,
            abi.encode(
                newConfig.poolKey,
                newConfig.tickLower,
                newConfig.tickUpper,
                newLiquidity,
                MAX_SLIPPAGE_INCREASE,
                MAX_SLIPPAGE_INCREASE,
                ActionConstants.MSG_SENDER,
                ZERO_BYTES
            )
        );
        bytes memory calls = planner.finalizeModifyLiquidityWithClose(config.poolKey);

        lpm.modifyLiquidities(calls, _deadline);
        {
            BalanceDelta netDelta = getNetDelta();

            uint256 balance0After = currency0.balanceOfSelf();
            uint256 balance1After = currency1.balanceOfSelf();

            // TODO: use clear so user does not pay 1 wei
            assertEq(netDelta.amount0(), -1 wei);
            assertEq(netDelta.amount1(), -1 wei);
            assertApproxEqAbs(balance0Before - balance0After, 0, 1 wei);
            assertApproxEqAbs(balance1Before - balance1After, 0, 1 wei);
        }

        // old position was burned
        vm.expectRevert();
        IERC721(address(lpm)).ownerOf(tokenId);

        {
            // old position has no liquidity
            uint128 liquidity = lpm.getPositionLiquidity(tokenId);
            assertEq(liquidity, 0);

            // new token was minted
            uint256 newTokenId = lpm.nextTokenId() - 1;
            assertEq(IERC721(address(lpm)).ownerOf(newTokenId), address(this));

            // new token has expected liquidity

            liquidity = lpm.getPositionLiquidity(newTokenId);
            assertEq(liquidity, newLiquidity);
        }
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
