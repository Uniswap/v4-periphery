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

import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {INonfungiblePositionManager} from "../../contracts/interfaces/INonfungiblePositionManager.sol";
import {NonfungiblePositionManager} from "../../contracts/NonfungiblePositionManager.sol";
import {
    LiquidityPosition,
    LiquidityPositionId,
    LiquidityPositionIdLibrary
} from "../../contracts/types/LiquidityPositionId.sol";

contract NonfungiblePositionManagerTest is Test, Deployers, GasSnapshot {
    using CurrencyLibrary for Currency;
    using LiquidityPositionIdLibrary for LiquidityPosition;

    NonfungiblePositionManager lpm;

    PoolId poolId;
    address alice = makeAddr("ALICE");

    function setUp() public {
        Deployers.deployFreshManagerAndRouters();
        Deployers.deployMintAndApprove2Currencies();

        (key, poolId) = initPool(currency0, currency1, IHooks(address(0)), 3000, SQRT_RATIO_1_1, ZERO_BYTES);

        lpm = new NonfungiblePositionManager(manager);

        IERC20(Currency.unwrap(currency0)).approve(address(lpm), type(uint256).max);
        IERC20(Currency.unwrap(currency1)).approve(address(lpm), type(uint256).max);
    }

    function test_mint_withLiquidityDelta() public {
        LiquidityPosition memory position = LiquidityPosition({key: key, tickLower: -600, tickUpper: 600});

        uint256 balance0Before = currency0.balanceOfSelf();
        uint256 balance1Before = currency1.balanceOfSelf();
        (uint256 tokenId, BalanceDelta delta) =
            lpm.mint(position, 1_00 ether, block.timestamp + 1, address(this), ZERO_BYTES);
        uint256 balance0After = currency0.balanceOfSelf();
        uint256 balance1After = currency0.balanceOfSelf();

        assertEq(tokenId, 1);
        assertEq(lpm.ownerOf(1), address(this));
        assertEq(balance0Before - balance0After, uint256(int256(delta.amount0())));
        assertEq(balance1Before - balance1After, uint256(int256(delta.amount1())));
    }

    function test_mint() public {
        LiquidityPosition memory position = LiquidityPosition({key: key, tickLower: -600, tickUpper: 600});

        uint256 amount0Desired = 100e18;
        uint256 amount1Desired = 100e18;

        uint256 balance0Before = currency0.balanceOfSelf();
        uint256 balance1Before = currency1.balanceOfSelf();
        INonfungiblePositionManager.MintParams memory params = INonfungiblePositionManager.MintParams({
            position: position,
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
        uint256 balance1After = currency0.balanceOfSelf();

        assertEq(tokenId, 1);
        assertEq(lpm.ownerOf(1), address(this));
        assertEq(uint256(int256(delta.amount0())), amount0Desired);
        assertEq(uint256(int256(delta.amount1())), amount1Desired);
        assertEq(balance0Before - balance0After, uint256(int256(delta.amount0())));
        assertEq(balance1Before - balance1After, uint256(int256(delta.amount1())));
    }

    function test_mint_recipient() public {
        LiquidityPosition memory position = LiquidityPosition({key: key, tickLower: -600, tickUpper: 600});
        uint256 amount0Desired = 100e18;
        uint256 amount1Desired = 100e18;
        INonfungiblePositionManager.MintParams memory params = INonfungiblePositionManager.MintParams({
            position: position,
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

    function test_mint_withLiquidityDelta_recipient() public {}

    function test_mint_slippageRevert() public {}

    function test_burn() public {}
    function test_collect() public {}
    function test_increaseLiquidity() public {}
    function test_decreaseLiquidity() public {}

    function test_mintTransferBurn() public {}
    function test_mintTransferCollect() public {}
    function test_mintTransferIncrease() public {}
    function test_mintTransferDecrease() public {}
}
