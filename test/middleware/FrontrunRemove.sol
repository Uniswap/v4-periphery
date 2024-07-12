// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {BaseHook} from "./../../contracts/BaseHook.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BaseHook} from "./../../contracts/BaseHook.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {console} from "./../../lib/forge-gas-snapshot/lib/forge-std/src/console.sol";

contract FrontrunRemove is BaseHook {
    constructor(IPoolManager _poolManager) BaseHook(_poolManager) {}

    bytes internal constant ZERO_BYTES = bytes("");
    uint160 public constant MIN_PRICE_LIMIT = TickMath.MIN_SQRT_PRICE + 1;

    // middleware implementations do not need to be mined
    function validateHookAddress(BaseHook _this) internal pure override {}

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: true,
            afterRemoveLiquidity: false,
            beforeSwap: false,
            afterSwap: false,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    function beforeRemoveLiquidity(
        address,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata,
        bytes calldata
    ) external override returns (bytes4) {
        BalanceDelta swapDelta = manager.swap(key, IPoolManager.SwapParams(true, 1000, MIN_PRICE_LIMIT), ZERO_BYTES);
        key.currency0.transfer(address(manager), uint128(-swapDelta.amount0()));
        manager.settle(key.currency0);
        manager.take(key.currency1, address(this), uint128(swapDelta.amount1()));
        return IHooks.beforeRemoveLiquidity.selector;
    }
}
