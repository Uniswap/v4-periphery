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
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";

import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";

import {INonfungiblePositionManager, Actions} from "../../src/interfaces/INonfungiblePositionManager.sol";
import {NonfungiblePositionManager} from "../../src/NonfungiblePositionManager.sol";
import {LiquidityRange, LiquidityRangeId, LiquidityRangeIdLibrary} from "../../src/types/LiquidityRange.sol";

import {LiquidityFuzzers} from "../shared/fuzz/LiquidityFuzzers.sol";

import {LiquidityOperations} from "../shared/LiquidityOperations.sol";
import {Planner} from "../utils/Planner.sol";

contract ExecuteTest is Test, Deployers, GasSnapshot, LiquidityFuzzers, LiquidityOperations {
    using FixedPointMathLib for uint256;
    using CurrencyLibrary for Currency;
    using LiquidityRangeIdLibrary for LiquidityRange;
    using PoolIdLibrary for PoolKey;
    using SafeCast for uint256;
    using Planner for Planner.Plan;
    using StateLibrary for IPoolManager;

    PoolId poolId;
    address alice = makeAddr("ALICE");
    address bob = makeAddr("BOB");

    uint256 constant STARTING_USER_BALANCE = 10_000_000 ether;

    // expresses the fee as a wad (i.e. 3000 = 0.003e18 = 0.30%)
    uint256 FEE_WAD;

    LiquidityRange range;

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

        // define a reusable range
        range = LiquidityRange({poolKey: key, tickLower: -300, tickUpper: 300});
    }

    function test_execute_increaseLiquidity_once(uint256 initialLiquidity, uint256 liquidityToAdd) public {
        initialLiquidity = bound(initialLiquidity, 1e18, 1000e18);
        liquidityToAdd = bound(liquidityToAdd, 1e18, 1000e18);
        _mint(range, initialLiquidity, address(this), ZERO_BYTES);
        uint256 tokenId = lpm.nextTokenId() - 1;

        _increaseLiquidity(tokenId, liquidityToAdd, ZERO_BYTES);

        bytes32 positionId =
            keccak256(abi.encodePacked(address(lpm), range.tickLower, range.tickUpper, bytes32(tokenId)));
        (uint256 liquidity,,) = manager.getPositionInfo(range.poolKey.toId(), positionId);

        assertEq(liquidity, initialLiquidity + liquidityToAdd);
    }

    function test_execute_increaseLiquidity_twice(
        uint256 initialiLiquidity,
        uint256 liquidityToAdd,
        uint256 liquidityToAdd2
    ) public {
        initialiLiquidity = bound(initialiLiquidity, 1e18, 1000e18);
        liquidityToAdd = bound(liquidityToAdd, 1e18, 1000e18);
        liquidityToAdd2 = bound(liquidityToAdd2, 1e18, 1000e18);
        _mint(range, initialiLiquidity, address(this), ZERO_BYTES);
        uint256 tokenId = lpm.nextTokenId() - 1;

        Planner.Plan memory planner = Planner.init();

        planner = planner.add(Actions.INCREASE, abi.encode(tokenId, liquidityToAdd, ZERO_BYTES));
        planner = planner.add(Actions.INCREASE, abi.encode(tokenId, liquidityToAdd2, ZERO_BYTES));

        planner = planner.finalize(range.poolKey);
        (bytes memory actions) = planner.zip();
        lpm.modifyLiquidities(actions, _deadline);

        bytes32 positionId =
            keccak256(abi.encodePacked(address(lpm), range.tickLower, range.tickUpper, bytes32(tokenId)));
        (uint256 liquidity,,) = manager.getPositionInfo(range.poolKey.toId(), positionId);

        assertEq(liquidity, initialiLiquidity + liquidityToAdd + liquidityToAdd2);
    }

    // this case doesnt make sense in real world usage, so it doesnt have a cool name. but its a good test case
    function test_execute_mintAndIncrease(uint256 initialLiquidity, uint256 liquidityToAdd) public {
        initialLiquidity = bound(initialLiquidity, 1e18, 1000e18);
        liquidityToAdd = bound(liquidityToAdd, 1e18, 1000e18);

        uint256 tokenId = 1; // assume that the .mint() produces tokenId=1, to be used in increaseLiquidity

        Planner.Plan memory planner = Planner.init();

        planner = planner.add(Actions.MINT, abi.encode(range, initialLiquidity, address(this), ZERO_BYTES));
        planner = planner.add(Actions.INCREASE, abi.encode(tokenId, liquidityToAdd, ZERO_BYTES));

        planner = planner.finalize(range.poolKey);
        bytes memory actions = planner.zip();
        lpm.modifyLiquidities(actions, _deadline);

        bytes32 positionId =
            keccak256(abi.encodePacked(address(lpm), range.tickLower, range.tickUpper, bytes32(tokenId)));
        (uint256 liquidity,,) = manager.getPositionInfo(range.poolKey.toId(), positionId);

        assertEq(liquidity, initialLiquidity + liquidityToAdd);
    }

    // rebalance: burn and mint
    function test_execute_rebalance_perfect() public {
        uint256 initialLiquidity = 100e18;

        // mint a position on range [-300, 300]
        BalanceDelta delta = _mint(range, initialLiquidity, address(this), ZERO_BYTES);
        uint256 tokenId = lpm.nextTokenId() - 1;

        // we'll burn and mint to [-60, 60], so calculate the liquidity units
        LiquidityRange memory newRange = LiquidityRange({poolKey: range.poolKey, tickLower: -60, tickUpper: 60});
        uint128 newLiquidity = LiquidityAmounts.getLiquidityForAmounts(
            SQRT_PRICE_1_1,
            TickMath.getSqrtPriceAtTick(newRange.tickLower),
            TickMath.getSqrtPriceAtTick(newRange.tickUpper),
            uint128(-delta.amount0()),
            uint128(-delta.amount1())
        );

        uint256 balance0Before = currency0.balanceOfSelf();
        uint256 balance1Before = currency1.balanceOfSelf();

        Planner.Plan memory planner = Planner.init();
        planner = planner.add(Actions.DECREASE, abi.encode(tokenId, initialLiquidity, ZERO_BYTES));
        planner = planner.add(Actions.BURN, abi.encode(tokenId));
        planner = planner.add(Actions.MINT, abi.encode(newRange, newLiquidity, address(this), ZERO_BYTES));
        planner = planner.finalize(range.poolKey);
        bytes[] memory data = lpm.modifyLiquidities(planner.zip(), _deadline);
        int256 delta0 = abi.decode(data[data.length - 2], (int256));
        int256 delta1 = abi.decode(data[data.length - 1], (int256));

        uint256 balance0After = currency0.balanceOfSelf();
        uint256 balance1After = currency1.balanceOfSelf();

        // wow there's 1 wei of imprecision, where the user is paying 1 wei of dust
        assertApproxEqAbs(delta0, 0, 1 wei);
        assertApproxEqAbs(delta1, 0, 1 wei);
        assertApproxEqAbs(balance0Before - balance0After, 0, 1 wei);
        assertApproxEqAbs(balance1Before - balance1After, 0, 1 wei);

        // old position was burned
        vm.expectRevert();
        lpm.ownerOf(tokenId);

        // old position has no liquidity
        bytes32 positionId =
            keccak256(abi.encodePacked(address(lpm), range.tickLower, range.tickUpper, bytes32(tokenId)));
        uint128 liquidity = manager.getPositionLiquidity(range.poolKey.toId(), positionId);
        assertEq(liquidity, 0);

        // new token was minted
        uint256 newTokenId = lpm.nextTokenId() - 1;
        assertEq(lpm.ownerOf(newTokenId), address(this));

        // new token has expected liquidity
        positionId =
            keccak256(abi.encodePacked(address(lpm), newRange.tickLower, newRange.tickUpper, bytes32(newTokenId)));
        liquidity = manager.getPositionLiquidity(range.poolKey.toId(), positionId);
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
