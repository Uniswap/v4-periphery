// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseHook} from "./../../contracts/BaseHook.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {console} from "forge-std/console.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {BaseImplementation} from "./../../contracts/middleware/BaseImplementation.sol";

contract HooksFrontrun is BaseImplementation {
    using SafeCast for uint256;

    bytes internal constant ZERO_BYTES = bytes("");
    uint160 public constant MIN_PRICE_LIMIT = TickMath.MIN_SQRT_PRICE + 1;
    uint160 public constant MAX_PRICE_LIMIT = TickMath.MAX_SQRT_PRICE - 1;

    BalanceDelta swapDelta;
    IPoolManager.SwapParams swapParams;

    constructor(IPoolManager _manager, address _middlewareFactory) BaseImplementation(_manager, _middlewareFactory) {}

    function getHookPermissions() public pure virtual override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    function beforeSwap(address, PoolKey calldata key, IPoolManager.SwapParams calldata params, bytes calldata)
        external
        override
        onlyByMiddleware
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        swapParams = params;
        console.log(params.zeroForOne);
        console.logInt(params.amountSpecified);
        swapDelta = manager.swap(key, params, ZERO_BYTES);
        console.log("beforeDelta");
        console.logInt(swapDelta.amount0());
        console.logInt(swapDelta.amount1());
        return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    function afterSwap(
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata hookData
    ) external override onlyByManager returns (bytes4, int128) {
        BalanceDelta afterDelta = manager.swap(
            key,
            IPoolManager.SwapParams(
                !swapParams.zeroForOne,
                -swapParams.amountSpecified,
                swapParams.zeroForOne ? MAX_PRICE_LIMIT : MIN_PRICE_LIMIT
            ),
            ZERO_BYTES
        );
        if (swapParams.zeroForOne) {
            int256 profit = afterDelta.amount0() + swapDelta.amount0();
            if (profit > 0) {
                // else hook reverts
                manager.mint(address(this), key.currency0.toId(), uint256(profit));
            }
        } else {
            int256 profit = afterDelta.amount1() + swapDelta.amount1();
            if (profit > 0) {
                // else hook reverts
                manager.mint(address(this), key.currency1.toId(), uint256(profit));
            }
        }
        console.log("afterDelta");
        console.logInt(afterDelta.amount0());
        console.logInt(afterDelta.amount1());
        return (BaseHook.afterSwap.selector, 0);
    }
}
