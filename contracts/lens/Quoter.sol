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
import {PathKeyLib} from "../libraries/PathKey.sol";

contract Quoter is IQuoter, IUnlockCallback {
    using Hooks for IHooks;
    using PoolIdLibrary for PoolKey;

    /// @dev cache used to check a safety condition in exact output swaps.
    uint256 private amountOutCached;

    // v4 Singleton contract
    IPoolManager public immutable manager;

    /// @dev custom error function selector length
    uint256 internal constant MINIMUM_CUSTOM_ERROR_LENGTH = 4;

    /// @dev function selector + length of bytes as uint256 + min length of revert reason padded to multiple of 32 bytes
    uint256 internal constant MINIMUM_REASON_LENGTH = 68;

    /// @dev min valid reason is 3-words long
    /// @dev int128[2] + sqrtPriceX96After padded to 32bytes + intializeTicksLoaded padded to 32bytes
    uint256 internal constant MINIMUM_VALID_RESPONSE_LENGTH = 96;

    /// @dev Only this address may call this function
    modifier selfOnly() {
        if (msg.sender != address(this)) revert NotSelf();
        _;
    }

    constructor(address _poolManager) {
        manager = IPoolManager(_poolManager);
    }

    /// @inheritdoc IQuoter
    function quoteExactInputSingle(QuoteExactSingleParams memory params)
        public
        override
        returns (int128[] memory deltaAmounts, uint160 sqrtPriceX96After, uint32 initializedTicksLoaded)
    {
        try manager.unlock(abi.encodeWithSelector(this._quoteExactInputSingle.selector, params)) {}
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
        try manager.unlock(abi.encodeWithSelector(this._quoteExactInput.selector, params)) {}
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
        if (params.sqrtPriceLimitX96 == 0) amountOutCached = params.exactAmount;

        try manager.unlock(abi.encodeWithSelector(this._quoteExactOutputSingle.selector, params)) {}
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
        try manager.unlock(abi.encodeWithSelector(this._quoteExactOutput.selector, params)) {}
        catch (bytes memory reason) {
            return _handleRevert(reason);
        }
    }

    /// @inheritdoc IUnlockCallback
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(manager)) {
            revert InvalidLockAcquiredSender();
        }
        if (msg.sender != address(this)) {
            revert InvalidLockCaller();
        }

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
            //if InvalidLockAcquiredSender()
            if (reason.length == MINIMUM_CUSTOM_ERROR_LENGTH) {
                assembly {
                    revert(reason, 4)
                }
            }
            if (reason.length < MINIMUM_REASON_LENGTH) {
                revert UnexpectedRevertBytes();
            }
            assembly {
                reason := add(reason, 0x04)
            }
            revert(abi.decode(reason, (string)));
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

        int128[] memory deltaAmounts = new int128[](pathLength + 1);
        uint160[] memory sqrtPriceX96AfterList = new uint160[](pathLength);
        uint32[] memory initializedTicksLoadedList = new uint32[](pathLength);
        Currency prevCurrencyOut;
        uint128 prevAmountOut;

        for (uint256 i = 0; i < pathLength; i++) {
            (PoolKey memory poolKey, bool zeroForOne) =
                PathKeyLib.getPoolAndSwapDirection(params.path[i], i == 0 ? params.exactCurrency : prevCurrencyOut);
            (, int24 tickBefore,,) = manager.getSlot0(poolKey.toId());

            (BalanceDelta curDeltas, uint160 sqrtPriceX96After, int24 tickAfter) = _swap(
                poolKey,
                zeroForOne,
                int256(int128(i == 0 ? params.exactAmount : prevAmountOut)),
                0,
                params.path[i].hookData
            );

            (int128 deltaIn, int128 deltaOut) =
                zeroForOne ? (curDeltas.amount0(), curDeltas.amount1()) : (curDeltas.amount1(), curDeltas.amount0());
            deltaAmounts[i] += deltaIn;
            deltaAmounts[i + 1] += deltaOut;

            prevAmountOut = zeroForOne ? uint128(-curDeltas.amount1()) : uint128(-curDeltas.amount0());
            prevCurrencyOut = params.path[i].intermediateCurrency;
            sqrtPriceX96AfterList[i] = sqrtPriceX96After;
            initializedTicksLoadedList[i] =
                PoolTicksCounter.countInitializedTicksLoaded(manager, poolKey, tickBefore, tickAfter);
        }
        bytes memory result = abi.encode(deltaAmounts, sqrtPriceX96AfterList, initializedTicksLoadedList);
        assembly {
            revert(add(0x20, result), mload(result))
        }
    }

    /// @dev quote an ExactInput swap on a pool, then revert with the result
    function _quoteExactInputSingle(QuoteExactSingleParams memory params) public selfOnly returns (bytes memory) {
        (, int24 tickBefore,,) = manager.getSlot0(params.poolKey.toId());

        (BalanceDelta deltas, uint160 sqrtPriceX96After, int24 tickAfter) = _swap(
            params.poolKey,
            params.zeroForOne,
            int256(int128(params.exactAmount)),
            params.sqrtPriceLimitX96,
            params.hookData
        );

        int128[] memory deltaAmounts = new int128[](2);

        deltaAmounts[0] = deltas.amount0();
        deltaAmounts[1] = deltas.amount1();

        uint32 initializedTicksLoaded =
            PoolTicksCounter.countInitializedTicksLoaded(manager, params.poolKey, tickBefore, tickAfter);
        bytes memory result = abi.encode(deltaAmounts, sqrtPriceX96After, initializedTicksLoaded);
        assembly {
            revert(add(0x20, result), mload(result))
        }
    }

    /// @dev quote an ExactOutput swap along a path of tokens, then revert with the result
    function _quoteExactOutput(QuoteExactParams memory params) public selfOnly returns (bytes memory) {
        uint256 pathLength = params.path.length;

        int128[] memory deltaAmounts = new int128[](pathLength + 1);
        uint160[] memory sqrtPriceX96AfterList = new uint160[](pathLength);
        uint32[] memory initializedTicksLoadedList = new uint32[](pathLength);
        Currency prevCurrencyIn;
        uint128 prevAmountIn;

        for (uint256 i = pathLength; i > 0; i--) {
            (PoolKey memory poolKey, bool oneForZero) = PathKeyLib.getPoolAndSwapDirection(
                params.path[i - 1], i == pathLength ? params.exactCurrency : prevCurrencyIn
            );

            (, int24 tickBefore,,) = manager.getSlot0(poolKey.toId());

            (BalanceDelta curDeltas, uint160 sqrtPriceX96After, int24 tickAfter) = _swap(
                poolKey,
                !oneForZero,
                -int256(int128(i == pathLength ? params.exactAmount : prevAmountIn)),
                0,
                params.path[i - 1].hookData
            );

            (int128 deltaIn, int128 deltaOut) =
                !oneForZero ? (curDeltas.amount0(), curDeltas.amount1()) : (curDeltas.amount1(), curDeltas.amount0());
            deltaAmounts[i - 1] += deltaIn;
            deltaAmounts[i] += deltaOut;

            prevAmountIn = !oneForZero ? uint128(curDeltas.amount0()) : uint128(curDeltas.amount1());
            prevCurrencyIn = params.path[i - 1].intermediateCurrency;
            sqrtPriceX96AfterList[i - 1] = sqrtPriceX96After;
            initializedTicksLoadedList[i - 1] =
                PoolTicksCounter.countInitializedTicksLoaded(manager, poolKey, tickBefore, tickAfter);
        }
        bytes memory result = abi.encode(deltaAmounts, sqrtPriceX96AfterList, initializedTicksLoadedList);
        assembly {
            revert(add(0x20, result), mload(result))
        }
    }

    /// @dev quote an ExactOutput swap on a pool, then revert with the result
    function _quoteExactOutputSingle(QuoteExactSingleParams memory params) public selfOnly returns (bytes memory) {
        (, int24 tickBefore,,) = manager.getSlot0(params.poolKey.toId());
        (BalanceDelta deltas, uint160 sqrtPriceX96After, int24 tickAfter) = _swap(
            params.poolKey,
            params.zeroForOne,
            -int256(uint256(params.exactAmount)),
            params.sqrtPriceLimitX96,
            params.hookData
        );
        int128[] memory deltaAmounts = new int128[](2);

        deltaAmounts[0] = deltas.amount0();
        deltaAmounts[1] = deltas.amount1();

        uint32 initializedTicksLoaded =
            PoolTicksCounter.countInitializedTicksLoaded(manager, params.poolKey, tickBefore, tickAfter);
        bytes memory result = abi.encode(deltaAmounts, sqrtPriceX96After, initializedTicksLoaded);
        assembly {
            revert(add(0x20, result), mload(result))
        }
    }

    /// @dev Execute a swap and return the amounts delta, as well as relevant pool state
    function _swap(
        PoolKey memory poolKey,
        bool zeroForOne,
        int256 amountSpecified,
        uint160 sqrtPriceLimitX96,
        bytes memory hookData
    ) private returns (BalanceDelta deltas, uint160 sqrtPriceX96After, int24 tickAfter) {
        deltas = manager.swap(
            poolKey,
            IPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: amountSpecified,
                sqrtPriceLimitX96: _sqrtPriceLimitOrDefault(sqrtPriceLimitX96, zeroForOne)
            }),
            hookData
        );
        (sqrtPriceX96After, tickAfter,,) = manager.getSlot0(poolKey.toId());
    }

    /// @dev return either the sqrtPriceLimit from user input, or the max/min value possible depending on trade direction
    function _sqrtPriceLimitOrDefault(uint160 sqrtPriceLimitX96, bool zeroForOne) private pure returns (uint160) {
        return sqrtPriceLimitX96 == 0
            ? zeroForOne ? TickMath.MIN_SQRT_RATIO + 1 : TickMath.MAX_SQRT_RATIO - 1
            : sqrtPriceLimitX96;
    }
}
