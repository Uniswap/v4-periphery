// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {BaseHook} from "./../../src/base/hooks/BaseHook.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";

contract FeeOnRemove is BaseHook {
    constructor(IPoolManager _poolManager) BaseHook(_poolManager) {}

    error FeeTooHigh();

    uint128 public liquidityFee = 543; // 5.43%
    uint128 public constant TOTAL_BIPS = 10000;

    // for testing
    function validateHookAddress(BaseHook _this) internal pure override {}

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: true,
            afterRemoveLiquidity: true,
            beforeSwap: false,
            afterSwap: false,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: true
        });
    }

    function setLiquidityFee(uint128 _liquidityFee) external {
        if (_liquidityFee > TOTAL_BIPS) revert FeeTooHigh();
        liquidityFee = _liquidityFee;
    }

    function beforeRemoveLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        bytes calldata
    ) external pure override returns (bytes4) {
        return BaseHook.beforeRemoveLiquidity.selector;
    }

    function afterRemoveLiquidity(
        address,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata,
        BalanceDelta delta,
        bytes calldata
    ) external override onlyByPoolManager returns (bytes4, BalanceDelta) {
        uint128 feeAmount0 = uint128(delta.amount0()) * liquidityFee / TOTAL_BIPS;
        uint128 feeAmount1 = uint128(delta.amount1()) * liquidityFee / TOTAL_BIPS;

        poolManager.mint(address(this), key.currency0.toId(), feeAmount0);
        poolManager.mint(address(this), key.currency1.toId(), feeAmount1);

        return (BaseHook.afterRemoveLiquidity.selector, toBalanceDelta(int128(feeAmount0), int128(feeAmount1)));
    }
}
