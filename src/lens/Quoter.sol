// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.20;

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IQuoter} from "../interfaces/IQuoter.sol";
import {PoolTicksCounter} from "../libraries/PoolTicksCounter.sol";
import {PathKey, PathKeyLib} from "../libraries/PathKey.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {SafeCallback} from "../base/SafeCallback.sol";

contract Quoter is IQuoter, SafeCallback {
    using Hooks for IHooks;
    using PoolIdLibrary for PoolKey;
    using PathKeyLib for PathKey;
    using StateLibrary for IPoolManager;

    /// @dev cache used to check a safety condition in exact output swaps.
    uint128 private amountOutCached;

    /// @dev min valid reason is 3-words long
    /// @dev int128[2] + sqrtPriceX96After padded to 32bytes + intializeTicksLoaded padded to 32bytes
    uint256 internal constant MINIMUM_VALID_RESPONSE_LENGTH = 96;

    struct QuoteResult {
        int128[] deltaAmounts;
        uint160[] sqrtPriceX96AfterList;
        uint32[] initializedTicksLoadedList;
    }

    struct QuoteCache {
        BalanceDelta curDeltas;
        uint128 prevAmount;
        int128 deltaIn;
        int128 deltaOut;
        int24 tickBefore;
        int24 tickAfter;
        Currency prevCurrency;
        uint160 sqrtPriceX96After;
    }

    /// @dev Only this address may call this function
    modifier selfOnly() {
        if (msg.sender != address(this)) revert NotSelf();
        _;
    }

    constructor(IPoolManager _poolManager) SafeCallback(_poolManager) {}

    /// @inheritdoc IQuoter
    function quoteExactInputSingle(QuoteExactSingleParams memory params)
        public
        override
        returns (int128[] memory deltaAmounts, uint160 sqrtPriceX96After, uint32 initializedTicksLoaded)
    {
        try poolManager.unlock(abi.encodeWithSelector(this._quoteExactInputSingle.selector, params)) {}
        catch (bytes memory reason) {
            return _handleRevertSingle(reason);
        }
    }

    /// @inheritdoc IQuoter
    function quoteExactInput(QuoteExactParams memory params)
        external
        returns (
            int128[] memory deltaAmounts,
            uint160[] memory sqrtPriceX96AfterList,
            uint32[] memory initializedTicksLoadedList
        )
    {
        try poolManager.unlock(abi.encodeWithSelector(this._quoteExactInput.selector, params)) {}
        catch (bytes memory reason) {
            return _handleRevert(reason);
        }
    }

    /// @inheritdoc IQuoter
    function quoteExactOutputSingle(QuoteExactSingleParams memory params)
        public
        override
        returns (int128[] memory deltaAmounts, uint160 sqrtPriceX96After, uint32 initializedTicksLoaded)
    {
        try poolManager.unlock(abi.encodeWithSelector(this._quoteExactOutputSingle.selector, params)) {}
        catch (bytes memory reason) {
            if (params.sqrtPriceLimitX96 == 0) delete amountOutCached;
            return _handleRevertSingle(reason);
        }
    }

    /// @inheritdoc IQuoter
    function quoteExactOutput(QuoteExactParams memory params)
        public
        override
        returns (
            int128[] memory deltaAmounts,
            uint160[] memory sqrtPriceX96AfterList,
            uint32[] memory initializedTicksLoadedList
        )
    {
        try poolManager.unlock(abi.encodeWithSelector(this._quoteExactOutput.selector, params)) {}
        catch (bytes memory reason) {
            return _handleRevert(reason);
        }
    }

    function _unlockCallback(bytes calldata data) internal override returns (bytes memory) {
        (bool success, bytes memory returnData) = address(this).call(data);
        if (success) return returnData;
        if (returnData.length == 0) revert LockFailure();
        // if the call failed, bubble up the reason
        /// @solidity memory-safe-assembly
        assembly {
            revert(add(returnData, 32), mload(returnData))
        }
    }

    /// @dev check revert bytes and pass through if considered valid; otherwise revert with different message
    function validateRevertReason(bytes memory reason) private pure returns (bytes memory) {
        if (reason.length < MINIMUM_VALID_RESPONSE_LENGTH) {
            revert UnexpectedRevertBytes(reason);
        }
        return reason;
    }

    /// @dev parse revert bytes from a single-pool quote
    function _handleRevertSingle(bytes memory reason)
        private
        pure
        returns (int128[] memory deltaAmounts, uint160 sqrtPriceX96After, uint32 initializedTicksLoaded)
    {
        reason = validateRevertReason(reason);
        (deltaAmounts, sqrtPriceX96After, initializedTicksLoaded) = abi.decode(reason, (int128[], uint160, uint32));
    }

    /// @dev parse revert bytes from a potentially multi-hop quote and return the delta amounts, sqrtPriceX96After, and initializedTicksLoaded
    function _handleRevert(bytes memory reason)
        private
        pure
        returns (
            int128[] memory deltaAmounts,
            uint160[] memory sqrtPriceX96AfterList,
            uint32[] memory initializedTicksLoadedList
        )
    {
        reason = validateRevertReason(reason);
        (deltaAmounts, sqrtPriceX96AfterList, initializedTicksLoadedList) =
            abi.decode(reason, (int128[], uint160[], uint32[]));
    }

    /// @dev quote an ExactInput swap along a path of tokens, then revert with the result
    function _quoteExactInput(QuoteExactParams memory params) public selfOnly returns (bytes memory) {
        uint256 pathLength = params.path.length;

        QuoteResult memory result = QuoteResult({
            deltaAmounts: new int128[](pathLength + 1),
            sqrtPriceX96AfterList: new uint160[](pathLength),
            initializedTicksLoadedList: new uint32[](pathLength)
        });
        QuoteCache memory cache;

        for (uint256 i = 0; i < pathLength; i++) {
            (PoolKey memory poolKey, bool zeroForOne) =
                params.path[i].getPoolAndSwapDirection(i == 0 ? params.exactCurrency : cache.prevCurrency);
            (, cache.tickBefore,,) = poolManager.getSlot0(poolKey.toId());

            (cache.curDeltas, cache.sqrtPriceX96After, cache.tickAfter) = _swap(
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
            result.initializedTicksLoadedList[i] =
                PoolTicksCounter.countInitializedTicksLoaded(poolManager, poolKey, cache.tickBefore, cache.tickAfter);
        }
        bytes memory r =
            abi.encode(result.deltaAmounts, result.sqrtPriceX96AfterList, result.initializedTicksLoadedList);
        assembly {
            revert(add(0x20, r), mload(r))
        }
    }

    /// @dev quote an ExactInput swap on a pool, then revert with the result
    function _quoteExactInputSingle(QuoteExactSingleParams memory params) public selfOnly returns (bytes memory) {
        (, int24 tickBefore,,) = poolManager.getSlot0(params.poolKey.toId());

        (BalanceDelta deltas, uint160 sqrtPriceX96After, int24 tickAfter) = _swap(
            params.poolKey,
            params.zeroForOne,
            -int256(int128(params.exactAmount)),
            params.sqrtPriceLimitX96,
            params.hookData
        );

        int128[] memory deltaAmounts = new int128[](2);

        deltaAmounts[0] = -deltas.amount0();
        deltaAmounts[1] = -deltas.amount1();

        uint32 initializedTicksLoaded =
            PoolTicksCounter.countInitializedTicksLoaded(poolManager, params.poolKey, tickBefore, tickAfter);
        bytes memory result = abi.encode(deltaAmounts, sqrtPriceX96After, initializedTicksLoaded);
        assembly {
            revert(add(0x20, result), mload(result))
        }
    }

    /// @dev quote an ExactOutput swap along a path of tokens, then revert with the result
    function _quoteExactOutput(QuoteExactParams memory params) public selfOnly returns (bytes memory) {
        uint256 pathLength = params.path.length;

        QuoteResult memory result = QuoteResult({
            deltaAmounts: new int128[](pathLength + 1),
            sqrtPriceX96AfterList: new uint160[](pathLength),
            initializedTicksLoadedList: new uint32[](pathLength)
        });
        QuoteCache memory cache;
        uint128 curAmountOut;

        for (uint256 i = pathLength; i > 0; i--) {
            curAmountOut = i == pathLength ? params.exactAmount : cache.prevAmount;
            amountOutCached = curAmountOut;

            (PoolKey memory poolKey, bool oneForZero) = PathKeyLib.getPoolAndSwapDirection(
                params.path[i - 1], i == pathLength ? params.exactCurrency : cache.prevCurrency
            );

            (, cache.tickBefore,,) = poolManager.getSlot0(poolKey.toId());

            (cache.curDeltas, cache.sqrtPriceX96After, cache.tickAfter) =
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
            result.initializedTicksLoadedList[i - 1] =
                PoolTicksCounter.countInitializedTicksLoaded(poolManager, poolKey, cache.tickBefore, cache.tickAfter);
        }
        bytes memory r =
            abi.encode(result.deltaAmounts, result.sqrtPriceX96AfterList, result.initializedTicksLoadedList);
        assembly {
            revert(add(0x20, r), mload(r))
        }
    }

    /// @dev quote an ExactOutput swap on a pool, then revert with the result
    function _quoteExactOutputSingle(QuoteExactSingleParams memory params) public selfOnly returns (bytes memory) {
        // if no price limit has been specified, cache the output amount for comparison in the swap callback
        if (params.sqrtPriceLimitX96 == 0) amountOutCached = params.exactAmount;

        (, int24 tickBefore,,) = poolManager.getSlot0(params.poolKey.toId());
        (BalanceDelta deltas, uint160 sqrtPriceX96After, int24 tickAfter) = _swap(
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

        uint32 initializedTicksLoaded =
            PoolTicksCounter.countInitializedTicksLoaded(poolManager, params.poolKey, tickBefore, tickAfter);
        bytes memory result = abi.encode(deltaAmounts, sqrtPriceX96After, initializedTicksLoaded);
        assembly {
            revert(add(0x20, result), mload(result))
        }
    }

    /// @dev Execute a swap and return the amounts delta, as well as relevant pool state
    /// @notice if amountSpecified > 0, the swap is exactInput, otherwise exactOutput
    function _swap(
        PoolKey memory poolKey,
        bool zeroForOne,
        int256 amountSpecified,
        uint160 sqrtPriceLimitX96,
        bytes memory hookData
    ) private returns (BalanceDelta deltas, uint160 sqrtPriceX96After, int24 tickAfter) {
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
        (sqrtPriceX96After, tickAfter,,) = poolManager.getSlot0(poolKey.toId());
    }

    /// @dev return either the sqrtPriceLimit from user input, or the max/min value possible depending on trade direction
    function _sqrtPriceLimitOrDefault(uint160 sqrtPriceLimitX96, bool zeroForOne) private pure returns (uint160) {
        return sqrtPriceLimitX96 == 0
            ? zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            : sqrtPriceLimitX96;
    }
}
