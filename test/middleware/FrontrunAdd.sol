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
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";

contract FrontrunAdd is BaseHook {
    using PoolIdLibrary for PoolKey;

    constructor(IPoolManager _poolManager) BaseHook(_poolManager) {}

    bytes internal constant ZERO_BYTES = bytes("");
    uint160 public constant MIN_PRICE_LIMIT = TickMath.MIN_SQRT_PRICE + 1;
    int256 public constant SWAP_AMOUNT = 1000;

    mapping(PoolId => bool) hasLiquidity;

    // for testing
    function validateHookAddress(BaseHook _this) internal pure override {}

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: true,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
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

    function beforeAddLiquidity(
        address,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata,
        bytes calldata
    ) external override returns (bytes4) {
        if (hasLiquidity[key.toId()]) {
            BalanceDelta swapDelta =
                manager.swap(key, IPoolManager.SwapParams(true, SWAP_AMOUNT, MIN_PRICE_LIMIT), ZERO_BYTES);
            key.currency0.transfer(address(manager), uint128(-swapDelta.amount0()));
            manager.settle(key.currency0);
            manager.take(key.currency1, address(this), uint128(swapDelta.amount1()));
        } else {
            hasLiquidity[key.toId()] = true;
        }
        return IHooks.beforeAddLiquidity.selector;
    }
}
