// SPDX-License-Identifier: GPL-2.0-or-later

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {QuoterRevert} from "../libraries/QuoterRevert.sol";
import {SqrtPriceLimitHelper} from "../libraries/SqrtPriceLimitHelper.sol";
import {SafeCallback} from "../base/SafeCallback.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";

abstract contract BaseV4Quoter is SafeCallback {
    using SqrtPriceLimitHelper for uint160;
    using QuoterRevert for *;
    using PoolIdLibrary for PoolId;

    error NotEnoughLiquidity(PoolId poolId);
    error LockFailure();
    error NotSelf();

    constructor(IPoolManager _poolManager) SafeCallback(_poolManager) {}

    /// @dev Only this address may call this function. Used to mimic internal functions, using an
    /// external call to catch and parse revert reasons
    modifier selfOnly() {
        if (msg.sender != address(this)) revert NotSelf();
        _;
    }

    function _unlockCallback(bytes calldata data) internal override returns (bytes memory) {
        // Call this contract with the data in question. Each quote path
        (bool success, bytes memory returnData) = address(this).call(data);
        if (success) return returnData;
        if (returnData.length == 0) revert LockFailure();
        returnData.bubbleReason();
    }

    /// @dev Execute a swap and return the balance delta
    /// @notice if amountSpecified < 0, the swap is exactInput, otherwise exactOutput
    function _swap(
        PoolKey memory poolKey,
        bool zeroForOne,
        int256 amountSpecified,
        uint160 sqrtPriceLimitX96,
        bytes calldata hookData
    ) internal returns (BalanceDelta swapDelta) {
        swapDelta = poolManager.swap(
            poolKey,
            IPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: amountSpecified,
                sqrtPriceLimitX96: sqrtPriceLimitX96.getSqrtPriceLimit(zeroForOne)
            }),
            hookData
        );

        // Check that the pool was not illiquid.
        int128 amountSpecifiedActual = (zeroForOne == (amountSpecified < 0)) ? swapDelta.amount0() : swapDelta.amount1();
        if (sqrtPriceLimitX96 == 0 && amountSpecifiedActual != amountSpecified) {
            revert NotEnoughLiquidity(poolKey.toId());
        }
    }
}
