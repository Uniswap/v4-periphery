// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {IQuoter} from "../interfaces/IQuoter.sol";
import {PathKey, PathKeyLibrary} from "../libraries/PathKey.sol";
import {RevertBytes} from "../libraries/RevertBytes.sol";
import {SafeCallback} from "../base/SafeCallback.sol";

contract Quoter is IQuoter, SafeCallback {
    using PoolIdLibrary for PoolKey;
    using PathKeyLibrary for PathKey;
    using StateLibrary for IPoolManager;
    using RevertBytes for bytes;

    /// @dev cache used to check a safety condition in exact output swaps.
    uint128 private amountOutCached;

    /// @dev Only this address may call this function. Used to mimic internal functions, using an
    /// external call to catch and parse revert reasons
    modifier selfOnly() {
        if (msg.sender != address(this)) revert NotSelf();
        _;
    }

    constructor(IPoolManager _poolManager) SafeCallback(_poolManager) {}

    /// @inheritdoc IQuoter
    function quoteExactInputSingle(QuoteExactSingleParams memory params)
        external
        returns (uint256 amountOut, uint160 sqrtPriceX96After, uint256 gasEstimate)
    {
        uint256 gasBefore = gasleft();
        try poolManager.unlock(abi.encodeCall(this._quoteExactInputSingle, (params))) {}
        catch (bytes memory reason) {
            gasEstimate = gasBefore - gasleft();
            (amountOut, sqrtPriceX96After) = reason.parseReturnDataSingle();
        }
    }

    /// @inheritdoc IQuoter
    function quoteExactInput(QuoteExactParams memory params)
        external
        returns (uint256 amountOut, uint160[] memory sqrtPriceX96AfterList, uint256 gasEstimate)
    {
        uint256 gasBefore = gasleft();
        try poolManager.unlock(abi.encodeCall(this._quoteExactInput, (params))) {}
        catch (bytes memory reason) {
            gasEstimate = gasBefore - gasleft();
            (amountOut, sqrtPriceX96AfterList) = reason.parseReturnData();
        }
    }

    /// @inheritdoc IQuoter
    function quoteExactOutputSingle(QuoteExactSingleParams memory params)
        external
        returns (uint256 amountIn, uint160 sqrtPriceX96After, uint256 gasEstimate)
    {
        uint256 gasBefore = gasleft();
        try poolManager.unlock(abi.encodeCall(this._quoteExactOutputSingle, (params))) {}
        catch (bytes memory reason) {
            gasEstimate = gasBefore - gasleft();
            if (params.sqrtPriceLimitX96 == 0) delete amountOutCached;
            (amountIn, sqrtPriceX96After) = reason.parseReturnDataSingle();
        }
    }

    /// @inheritdoc IQuoter
    function quoteExactOutput(QuoteExactParams memory params)
        external
        returns (uint256 amountIn, uint160[] memory sqrtPriceX96AfterList, uint256 gasEstimate)
    {
        uint256 gasBefore = gasleft();
        try poolManager.unlock(abi.encodeCall(this._quoteExactOutput, (params))) {}
        catch (bytes memory reason) {
            gasEstimate = gasBefore - gasleft();
            (amountIn, sqrtPriceX96AfterList) = reason.parseReturnData();
        }
    }

    function _unlockCallback(bytes calldata data) internal override returns (bytes memory) {
        // Call this contract with the data in question. Each quote path
        (bool success, bytes memory returnData) = address(this).call(data);
        if (success) return returnData;
        if (returnData.length == 0) revert LockFailure();
        returnData.revertWith();
    }

    /// @dev external function called within the _unlockCallback, to simulate an exact input swap, then revert with the result
    function _quoteExactInput(QuoteExactParams calldata params) external selfOnly returns (bytes memory) {
        uint256 pathLength = params.path.length;

        uint160[] memory sqrtPriceX96AfterList = new uint160[](pathLength);
        BalanceDelta swapDelta;
        uint128 amountIn = params.exactAmount;
        Currency inputCurrency = params.exactCurrency;
        PathKey calldata pathKey;

        for (uint256 i = 0; i < pathLength; i++) {
            pathKey = params.path[i];
            (PoolKey memory poolKey, bool zeroForOne) = pathKey.getPoolAndSwapDirection(inputCurrency);

            (swapDelta, sqrtPriceX96AfterList[i]) =
                _swap(poolKey, zeroForOne, -int256(int128(amountIn)), 0, pathKey.hookData);

            amountIn = zeroForOne ? uint128(swapDelta.amount1()) : uint128(swapDelta.amount0());
            inputCurrency = pathKey.intermediateCurrency;
        }
        // amountIn after the loop actually holds the amountOut of the trade
        bytes memory encodedResult = abi.encode(amountIn, sqrtPriceX96AfterList);
        encodedResult.revertWith();
    }

    /// @dev external function called within the _unlockCallback, to simulate a single-hop exact input swap, then revert with the result
    function _quoteExactInputSingle(QuoteExactSingleParams calldata params) external selfOnly returns (bytes memory) {
        (BalanceDelta deltas, uint160 sqrtPriceX96After) = _swap(
            params.poolKey,
            params.zeroForOne,
            -int256(int128(params.exactAmount)),
            params.sqrtPriceLimitX96,
            params.hookData
        );

        // the output delta of a swap is positive
        uint256 amountOut = params.zeroForOne ? uint128(deltas.amount1()) : uint128(deltas.amount0());

        bytes memory encodedResult = abi.encode(amountOut, sqrtPriceX96After);
        encodedResult.revertWith();
    }

    /// @dev external function called within the _unlockCallback, to simulate an exact output swap, then revert with the result
    function _quoteExactOutput(QuoteExactParams calldata params) external selfOnly returns (bytes memory) {
        uint256 pathLength = params.path.length;

        uint160[] memory sqrtPriceX96AfterList = new uint160[](pathLength);
        BalanceDelta swapDelta;
        uint128 amountOut = params.exactAmount;
        Currency outputCurrency = params.exactCurrency;
        PathKey calldata pathKey;

        for (uint256 i = pathLength; i > 0; i--) {
            pathKey = params.path[i - 1];
            amountOutCached = amountOut;

            (PoolKey memory poolKey, bool oneForZero) = pathKey.getPoolAndSwapDirection(outputCurrency);

            (swapDelta, sqrtPriceX96AfterList[i - 1]) =
                _swap(poolKey, !oneForZero, int256(uint256(amountOut)), 0, pathKey.hookData);

            // always clear because sqrtPriceLimitX96 is set to 0 always
            delete amountOutCached;

            amountOut = oneForZero ? uint128(-swapDelta.amount1()) : uint128(-swapDelta.amount0());

            outputCurrency = pathKey.intermediateCurrency;
        }
        // amountOut after the loop exits actually holds the amountIn of the trade
        bytes memory encodedResult = abi.encode(amountOut, sqrtPriceX96AfterList);
        encodedResult.revertWith();
    }

    /// @dev external function called within the _unlockCallback, to simulate a single-hop exact output swap, then revert with the result
    function _quoteExactOutputSingle(QuoteExactSingleParams calldata params) external selfOnly returns (bytes memory) {
        // if no price limit has been specified, cache the output amount for comparison inside the _swap function
        if (params.sqrtPriceLimitX96 == 0) amountOutCached = params.exactAmount;

        (BalanceDelta deltas, uint160 sqrtPriceX96After) = _swap(
            params.poolKey,
            params.zeroForOne,
            int256(uint256(params.exactAmount)),
            params.sqrtPriceLimitX96,
            params.hookData
        );

        if (amountOutCached != 0) delete amountOutCached;

        // the input delta of a swap is negative so we must flip it
        uint256 amountIn = params.zeroForOne ? uint128(-deltas.amount0()) : uint128(-deltas.amount1());

        bytes memory encodedResult = abi.encode(amountIn, sqrtPriceX96After);
        encodedResult.revertWith();
    }

    /// @dev Execute a swap and return the amount deltas, as well as the sqrtPrice from the end of the swap
    /// @notice if amountSpecified < 0, the swap is exactInput, otherwise exactOutput
    function _swap(
        PoolKey memory poolKey,
        bool zeroForOne,
        int256 amountSpecified,
        uint160 sqrtPriceLimitX96,
        bytes calldata hookData
    ) private returns (BalanceDelta deltas, uint160 sqrtPriceX96After) {
        deltas = poolManager.swap(
            poolKey,
            IPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: amountSpecified,
                sqrtPriceLimitX96: _sqrtPriceLimitOrDefault(sqrtPriceLimitX96, zeroForOne)
            }),
            hookData
        );
        // only exactOut case
        if (amountOutCached != 0 && amountOutCached != uint128(zeroForOne ? deltas.amount1() : deltas.amount0())) {
            revert InsufficientAmountOut();
        }
        (sqrtPriceX96After,,,) = poolManager.getSlot0(poolKey.toId());
    }

    /// @dev return either the sqrtPriceLimit from user input, or the max/min value possible depending on trade direction
    function _sqrtPriceLimitOrDefault(uint160 sqrtPriceLimitX96, bool zeroForOne) private pure returns (uint160) {
        return sqrtPriceLimitX96 == 0
            ? zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            : sqrtPriceLimitX96;
    }
}
