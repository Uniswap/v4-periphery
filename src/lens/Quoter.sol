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

    struct QuoteResult {
        int128[] deltaAmounts;
        uint160[] sqrtPriceX96AfterList;
    }

    struct QuoteCache {
        BalanceDelta curDeltas;
        uint128 prevAmount;
        int128 deltaIn;
        int128 deltaOut;
        Currency prevCurrency;
        uint160 sqrtPriceX96After;
    }

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
        returns (int128[] memory deltaAmounts, uint160 sqrtPriceX96After, uint256 gasEstimate)
    {
        uint256 gasBefore = gasleft();
        try poolManager.unlock(abi.encodeCall(this._quoteExactInputSingle, (params))) {}
        catch (bytes memory reason) {
            gasEstimate = gasBefore - gasleft();
            (deltaAmounts, sqrtPriceX96After) = reason.parseReturnDataSingle();
        }
    }

    /// @inheritdoc IQuoter
    function quoteExactInput(QuoteExactParams memory params)
        external
        returns (int128[] memory deltaAmounts, uint160[] memory sqrtPriceX96AfterList, uint256 gasEstimate)
    {
        uint256 gasBefore = gasleft();
        try poolManager.unlock(abi.encodeCall(this._quoteExactInput, (params))) {}
        catch (bytes memory reason) {
            gasEstimate = gasBefore - gasleft();
            (deltaAmounts, sqrtPriceX96AfterList) = reason.parseReturnData();
        }
    }

    /// @inheritdoc IQuoter
    function quoteExactOutputSingle(QuoteExactSingleParams memory params)
        external
        returns (int128[] memory deltaAmounts, uint160 sqrtPriceX96After, uint256 gasEstimate)
    {
        uint256 gasBefore = gasleft();
        try poolManager.unlock(abi.encodeCall(this._quoteExactOutputSingle, (params))) {}
        catch (bytes memory reason) {
            gasEstimate = gasBefore - gasleft();
            if (params.sqrtPriceLimitX96 == 0) delete amountOutCached;
            (deltaAmounts, sqrtPriceX96After) = reason.parseReturnDataSingle();
        }
    }

    /// @inheritdoc IQuoter
    function quoteExactOutput(QuoteExactParams memory params)
        external
        returns (int128[] memory deltaAmounts, uint160[] memory sqrtPriceX96AfterList, uint256 gasEstimate)
    {
        uint256 gasBefore = gasleft();
        try poolManager.unlock(abi.encodeCall(this._quoteExactOutput, (params))) {}
        catch (bytes memory reason) {
            gasEstimate = gasBefore - gasleft();
            (deltaAmounts, sqrtPriceX96AfterList) = reason.parseReturnData();
        }
    }

    function _unlockCallback(bytes calldata data) internal override returns (bytes memory) {
        // Call this contract with the data in question. Each quote path
        (bool success, bytes memory returnData) = address(this).call(data);
        if (success) return returnData;
        if (returnData.length == 0) revert LockFailure();
        returnData.revertWith();
    }

    /// @dev quote an ExactInput swap along a path of tokens, then revert with the result
    function _quoteExactInput(QuoteExactParams calldata params) external selfOnly returns (bytes memory) {
        uint256 pathLength = params.path.length;

        QuoteResult memory result =
            QuoteResult({deltaAmounts: new int128[](pathLength + 1), sqrtPriceX96AfterList: new uint160[](pathLength)});
        QuoteCache memory cache;

        for (uint256 i = 0; i < pathLength; i++) {
            (PoolKey memory poolKey, bool zeroForOne) =
                params.path[i].getPoolAndSwapDirection(i == 0 ? params.exactCurrency : cache.prevCurrency);

            (cache.curDeltas, cache.sqrtPriceX96After) = _swap(
                poolKey,
                zeroForOne,
                -int256(int128(i == 0 ? params.exactAmount : cache.prevAmount)),
                0,
                params.path[i].hookData
            );

            (cache.deltaIn, cache.deltaOut) = zeroForOne
                ? (-cache.curDeltas.amount0(), -cache.curDeltas.amount1())
                : (-cache.curDeltas.amount1(), -cache.curDeltas.amount0());
            result.deltaAmounts[i] += cache.deltaIn;
            result.deltaAmounts[i + 1] += cache.deltaOut;

            cache.prevAmount = zeroForOne ? uint128(cache.curDeltas.amount1()) : uint128(cache.curDeltas.amount0());
            cache.prevCurrency = params.path[i].intermediateCurrency;
            result.sqrtPriceX96AfterList[i] = cache.sqrtPriceX96After;
        }
        bytes memory encodedResult = abi.encode(result.deltaAmounts, result.sqrtPriceX96AfterList);
        encodedResult.revertWith();
    }

    /// @dev quote an ExactInput swap on a pool, then revert with the result
    function _quoteExactInputSingle(QuoteExactSingleParams calldata params) external selfOnly returns (bytes memory) {
        (BalanceDelta deltas, uint160 sqrtPriceX96After) = _swap(
            params.poolKey,
            params.zeroForOne,
            -int256(int128(params.exactAmount)),
            params.sqrtPriceLimitX96,
            params.hookData
        );

        int128[] memory deltaAmounts = new int128[](2);

        deltaAmounts[0] = -deltas.amount0();
        deltaAmounts[1] = -deltas.amount1();

        bytes memory encodedResult = abi.encode(deltaAmounts, sqrtPriceX96After);
        encodedResult.revertWith();
    }

    /// @dev quote an ExactOutput swap along a path of tokens, then revert with the result
    function _quoteExactOutput(QuoteExactParams calldata params) external selfOnly returns (bytes memory) {
        uint256 pathLength = params.path.length;

        QuoteResult memory result =
            QuoteResult({deltaAmounts: new int128[](pathLength + 1), sqrtPriceX96AfterList: new uint160[](pathLength)});
        QuoteCache memory cache;
        uint128 curAmountOut;

        for (uint256 i = pathLength; i > 0; i--) {
            curAmountOut = i == pathLength ? params.exactAmount : cache.prevAmount;
            amountOutCached = curAmountOut;

            (PoolKey memory poolKey, bool oneForZero) = PathKeyLibrary.getPoolAndSwapDirection(
                params.path[i - 1], i == pathLength ? params.exactCurrency : cache.prevCurrency
            );

            (cache.curDeltas, cache.sqrtPriceX96After) =
                _swap(poolKey, !oneForZero, int256(uint256(curAmountOut)), 0, params.path[i - 1].hookData);

            // always clear because sqrtPriceLimitX96 is set to 0 always
            delete amountOutCached;
            (cache.deltaIn, cache.deltaOut) = !oneForZero
                ? (-cache.curDeltas.amount0(), -cache.curDeltas.amount1())
                : (-cache.curDeltas.amount1(), -cache.curDeltas.amount0());
            result.deltaAmounts[i - 1] += cache.deltaIn;
            result.deltaAmounts[i] += cache.deltaOut;

            cache.prevAmount = !oneForZero ? uint128(-cache.curDeltas.amount0()) : uint128(-cache.curDeltas.amount1());
            cache.prevCurrency = params.path[i - 1].intermediateCurrency;
            result.sqrtPriceX96AfterList[i - 1] = cache.sqrtPriceX96After;
        }
        bytes memory encodedResult = abi.encode(result.deltaAmounts, result.sqrtPriceX96AfterList);
        encodedResult.revertWith();
    }

    /// @dev quote an ExactOutput swap on a pool, then revert with the result
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
        int128[] memory deltaAmounts = new int128[](2);

        deltaAmounts[0] = -deltas.amount0();
        deltaAmounts[1] = -deltas.amount1();

        bytes memory encodedResult = abi.encode(deltaAmounts, sqrtPriceX96After);
        encodedResult.revertWith();
    }

    /// @dev Execute a swap and return the amounts delta, as well as relevant pool state
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
