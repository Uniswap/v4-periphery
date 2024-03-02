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
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {LiquidityAmounts} from "../../contracts/libraries/LiquidityAmounts.sol";

import {IERC20} from "forge-std/interfaces/IERC20.sol";

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

    function setUp() public {
        Deployers.deployFreshManagerAndRouters();
        Deployers.deployMintAndApprove2Currencies();

        (key, poolId) = initPool(currency0, currency1, IHooks(address(0)), 3000, SQRT_RATIO_1_1, ZERO_BYTES);

        lpm = new NonfungiblePositionManager(manager);

        IERC20(Currency.unwrap(currency0)).approve(address(lpm), type(uint256).max);
        IERC20(Currency.unwrap(currency1)).approve(address(lpm), type(uint256).max);
    }

    function test_mint() public {
        LiquidityPosition memory position = LiquidityPosition({key: key, tickLower: -600, tickUpper: 600});

        uint256 balance0Before = currency0.balanceOfSelf();
        uint256 balance1Before = currency1.balanceOfSelf();
        console2.log(balance0Before);
        console2.log(balance1Before);
        console2.log(address(this));
        console2.log(IERC20(Currency.unwrap(currency0)).allowance(address(this), address(lpm)));
        uint256 tokenId = lpm.mint(position, 1_00 ether, block.timestamp + 1, address(this), ZERO_BYTES);
        assertEq(tokenId, 1);
        uint256 balance0After = currency0.balanceOfSelf();
        uint256 balance1After = currency0.balanceOfSelf();
    }
}
