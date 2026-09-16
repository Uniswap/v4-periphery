// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {BaseTestHooks} from "@uniswap/v4-core/src/test/BaseTestHooks.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

/// @dev Sandwiches a mint from inside the add-liquidity callbacks: pushes the price to `pushTick`
///      in beforeAddLiquidity and restores it in afterAddLiquidity. Inert until armed.
contract MockLiquiditySandwichHook is BaseTestHooks {
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    IPoolManager public poolManager;
    bool public armed;
    int24 public pushTick;
    uint160 internal restoreSqrtPriceX96;

    function arm(IPoolManager _poolManager, int24 _pushTick) external {
        poolManager = _poolManager;
        pushTick = _pushTick;
        armed = true;
    }

    function disarm() external {
        armed = false;
    }

    function beforeAddLiquidity(address, PoolKey calldata key, ModifyLiquidityParams calldata, bytes calldata)
        external
        override
        returns (bytes4)
    {
        if (armed) {
            (restoreSqrtPriceX96,,,) = poolManager.getSlot0(key.toId());
            _swapTo(key, TickMath.getSqrtPriceAtTick(pushTick));
        }
        return IHooks.beforeAddLiquidity.selector;
    }

    function afterAddLiquidity(
        address,
        PoolKey calldata key,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external override returns (bytes4, BalanceDelta) {
        if (armed) _swapTo(key, restoreSqrtPriceX96);
        return (IHooks.afterAddLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }

    function _swapTo(PoolKey calldata key, uint160 targetSqrtPriceX96) internal {
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(key.toId());
        if (sqrtPriceX96 == targetSqrtPriceX96) return;
        poolManager.swap(
            key,
            SwapParams({
                zeroForOne: sqrtPriceX96 > targetSqrtPriceX96,
                amountSpecified: -int256(1e30),
                sqrtPriceLimitX96: targetSqrtPriceX96
            }),
            ""
        );
        _settle(key.currency0);
        _settle(key.currency1);
    }

    function _settle(Currency currency) internal {
        int256 delta = poolManager.currencyDelta(address(this), currency);
        if (delta < 0) {
            poolManager.sync(currency);
            MockERC20(Currency.unwrap(currency)).transfer(address(poolManager), uint256(-delta));
            poolManager.settle();
        } else if (delta > 0) {
            poolManager.take(currency, address(this), uint256(delta));
        }
    }
}
