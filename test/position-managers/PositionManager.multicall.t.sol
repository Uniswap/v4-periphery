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

contract MulticallTest is Test, Deployers, GasSnapshot, LiquidityFuzzers, LiquidityOperations {
    using FixedPointMathLib for uint256;
    using CurrencyLibrary for Currency;
    using LiquidityRangeIdLibrary for LiquidityRange;
    using Planner for Planner.Plan;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    PoolId poolId;
    address alice;
    uint256 alicePK;
    address bob;

    uint256 constant STARTING_USER_BALANCE = 10_000_000 ether;

    function setUp() public {
        (alice, alicePK) = makeAddrAndKey("ALICE");
        (bob,) = makeAddrAndKey("BOB");

        Deployers.deployFreshManagerAndRouters();
        Deployers.deployMintAndApprove2Currencies();

        (key, poolId) = initPool(currency0, currency1, IHooks(address(0)), 3000, SQRT_PRICE_1_1, ZERO_BYTES);

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

    function test_multicall_initializePool_mint() public {
        key = PoolKey({currency0: currency0, currency1: currency1, fee: 0, tickSpacing: 10, hooks: IHooks(address(0))});

        // Use multicall to initialize a pool and mint liquidity
        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeWithSelector(
            NonfungiblePositionManager(lpm).initializePool.selector, key, SQRT_PRICE_1_1, ZERO_BYTES
        );

        LiquidityRange memory range = LiquidityRange({
            poolKey: key,
            tickLower: TickMath.minUsableTick(key.tickSpacing),
            tickUpper: TickMath.maxUsableTick(key.tickSpacing)
        });

        Planner.Plan memory planner = Planner.init();
        planner = planner.add(Actions.MINT, abi.encode(range, 100e18, address(this), ZERO_BYTES));
        bytes memory actions = planner.finalize(range.poolKey);

        calls[1] =
            abi.encodeWithSelector(NonfungiblePositionManager(lpm).modifyLiquidities.selector, actions, _deadline);

        lpm.multicall(calls);

        // test swap, doesn't revert
        swap(key, true, -1e18, ZERO_BYTES);
    }

    function test_multicall_permitAndDecrease() public {
        LiquidityRange memory range = LiquidityRange({poolKey: key, tickLower: -60, tickUpper: 60});
        uint256 liquidityAlice = 1e18;
        vm.startPrank(alice);
        mint(range, liquidityAlice, alice, ZERO_BYTES);
        vm.stopPrank();
        uint256 tokenId = lpm.nextTokenId() - 1;

        // Alice gives Bob permission to operate on her liquidity
        uint256 nonce = 1;
        bytes32 digest = lpm.getDigest(bob, tokenId, nonce, block.timestamp + 1);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(alicePK, digest);

        // bob gives himself permission and decreases liquidity
        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeWithSelector(
            NonfungiblePositionManager(lpm).permit.selector, bob, tokenId, block.timestamp + 1, nonce, v, r, s
        );
        uint256 liquidityToRemove = 0.4444e18;
        bytes memory actions = LiquidityOperations.getDecreaseEncoded(tokenId, 0.4444e18, ZERO_BYTES);
        calls[1] =
            abi.encodeWithSelector(NonfungiblePositionManager(lpm).modifyLiquidities.selector, actions, _deadline);

        vm.prank(bob);
        lpm.multicall(calls);

        bytes32 positionId =
            keccak256(abi.encodePacked(address(lpm), range.tickLower, range.tickUpper, bytes32(tokenId)));
        (uint256 liquidity,,) = manager.getPositionInfo(range.poolKey.toId(), positionId);
        assertEq(liquidity, liquidityAlice - liquidityToRemove);
    }
}
