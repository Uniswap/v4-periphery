// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {BaseHook} from "./../../contracts/BaseHook.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BaseHook} from "./../../contracts/BaseHook.sol";

contract FeeOnRemove is BaseHook {
    constructor(IPoolManager _poolManager) BaseHook(_poolManager) {}

    uint128 public constant LIQUIDITY_FEE = 543; // 5.43%
    uint128 public constant TOTAL_BIPS = 10000;

    // middleware implementations do not need to be mined
    function validateHookAddress(BaseHook _this) internal pure override {}

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: true,
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

    function afterRemoveLiquidity(
        address,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata,
        BalanceDelta delta,
        bytes calldata
    ) external override onlyByManager returns (bytes4, BalanceDelta) {
        uint128 feeAmount0 = uint128(delta.amount0()) * LIQUIDITY_FEE / TOTAL_BIPS;
        uint128 feeAmount1 = uint128(delta.amount1()) * LIQUIDITY_FEE / TOTAL_BIPS;

        manager.mint(address(this), key.currency0.toId(), feeAmount0);
        manager.mint(address(this), key.currency1.toId(), feeAmount1);

        return (IHooks.afterRemoveLiquidity.selector, toBalanceDelta(int128(feeAmount0), int128(feeAmount1)));
    }
}
