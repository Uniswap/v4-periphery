// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseHook} from "./../../contracts/BaseHook.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {BaseHook} from "./../../contracts/BaseHook.sol";

contract HooksFrontrun is BaseHook {
    using SafeCast for uint256;

    bytes internal constant ZERO_BYTES = bytes("");
    uint160 public constant MIN_PRICE_LIMIT = TickMath.MIN_SQRT_PRICE + 1;
    uint160 public constant MAX_PRICE_LIMIT = TickMath.MAX_SQRT_PRICE - 1;

    BalanceDelta swapDelta;
    IPoolManager.SwapParams swapParams;

    constructor(IPoolManager _manager) BaseHook(_manager) {}

    // for testing
    function validateHookAddress(BaseHook _this) internal pure override {}

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
        onlyByManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        swapParams = params;
        swapDelta = manager.swap(key, params, ZERO_BYTES);
        return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    function afterSwap(address, PoolKey calldata key, IPoolManager.SwapParams calldata, BalanceDelta, bytes calldata)
        external
        override
        onlyByManager
        returns (bytes4, int128)
    {
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
        return (BaseHook.afterSwap.selector, 0);
    }
}
