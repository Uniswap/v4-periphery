// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "forge-std/console2.sol";
import "forge-std/Script.sol";

import {ERC20} from "solmate/src/tokens/ERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {LiquidityOperations} from "../test/shared/LiquidityOperations.sol";
import {StateView} from "../src/lens/StateView.sol";
import {PositionConfig} from "../test/shared/PositionConfig.sol";
import {IPositionManager} from "../src/interfaces/IPositionManager.sol";
import {PositionManager} from "../src/PositionManager.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";

contract CreatePool is Script, LiquidityOperations {
    // native
    Currency constant token0 = Currency.wrap(address(0));
    uint256 constant amount0Desired = 0.001 ether;
    Currency constant token1 = Currency.wrap(0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238);
    uint256 constant amount1Desired = 3000000;
    uint160 public constant SQRT_PRICE_1_1 = 79228162514264337593543950336;
    uint24 constant fee = 500;
    int24 constant tickSpacing = 40;
    uint160 constant sqrtPriceX96 = SQRT_PRICE_1_1;
    int24 tickLower = -4000;
    int24 tickUpper = 4000;

    function setUp() public {}

    function run(IPoolManager poolManager, IPositionManager posm, IAllowanceTransfer permit2, address recipient)
        public
    {
        PoolKey memory key = PoolKey(token0, token1, fee, tickSpacing, IHooks(address(0)));
        PositionConfig memory config = PositionConfig({poolKey: key, tickLower: tickLower, tickUpper: tickUpper});
        uint256 tokenId = posm.nextTokenId();

        uint256 liquidityToAdd = LiquidityAmounts.getLiquidityForAmounts(
            SQRT_PRICE_1_1,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            amount0Desired,
            amount1Desired
        );
        bytes memory calls = getMintEncoded(config, liquidityToAdd, recipient, new bytes(0));

        vm.startBroadcast();
        ERC20(Currency.unwrap(token1)).approve(address(permit2), type(uint256).max);

        poolManager.initialize(key, sqrtPriceX96, new bytes(0));
        permit2.approve(Currency.unwrap(token0), address(posm), type(uint160).max, type(uint48).max);
        permit2.approve(Currency.unwrap(token1), address(posm), type(uint160).max, type(uint48).max);

        posm.modifyLiquidities{value: amount0Desired}(calls, block.timestamp + 100000);

        vm.stopBroadcast();
    }
}
