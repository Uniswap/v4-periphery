// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.20;

import "forge-std/console2.sol";
import {Hooks} from "@uniswap/v4-core/contracts/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/contracts/libraries/TickMath.sol";
import {IHooks} from "@uniswap/v4-core/contracts/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/contracts/interfaces/IPoolManager.sol";
import {BalanceDelta} from "@uniswap/v4-core/contracts/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/contracts/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/contracts/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/contracts/types/PoolId.sol";
import "../libraries/SwapIntention.sol";
import {IQuoter} from "../interfaces/IQuoter.sol";
import {PoolTicksCounter} from "../libraries/PoolTicksCounter.sol";

contract Quoter is IQuoter {
    using PoolIdLibrary for PoolKey;
    using Hooks for IHooks;

    /// @dev Transient storage variable used to check a safety condition in exact output swaps.
    uint256 private amountOutCached;

    // v4 Singleton contract
    IPoolManager public immutable manager;

    /// @dev function selector + length of bytes as uint256 + min length of revert reason padded to multiple of 32 bytes
    uint256 internal constant MINIMUM_REASON_LENGTH = 68;

    /// @dev min valid reason is 3-words long
    /// @dev int128[2] + sqrtPriceX96After padded to 32bytes + intializeTicksLoaded padded to 32bytes
    uint256 internal constant MINIMUM_VALID_REASON_LENGTH = 96;

    constructor(address _poolManager) {
        manager = IPoolManager(_poolManager);
    }

    /// @inheritdoc IQuoter
    function quoteExactInputSingle(ExactInputSingleParams memory params)
        public
        override
        returns (int128[] memory deltaAmounts, uint160 sqrtPriceX96After, uint32 initializedTicksLoaded)
    {
        try manager.lock(abi.encode(SwapInfo(SwapType.ExactInputSingle, abi.encode(params)))) {}
        catch (bytes memory reason) {
            return _handleRevertSingle(reason, params.poolKey);
        }
    }

    /// @inheritdoc IQuoter
    function quoteExactInput(ExactInputParams memory params)
        external
        returns (
            int128[] memory deltaAmounts,
            uint160[] memory sqrtPriceX96AfterList,
            uint32[] memory initializedTicksLoadedList
        )
    {
        try manager.lock(abi.encode(SwapInfo(SwapType.ExactInput, abi.encode(params)))) {}
        catch (bytes memory reason) {
            return _handleRevert(reason);
        }
    }

    function quoteExactInputBatch(ExactInputSingleBatchParams memory params)
        external
        returns (
            IQuoter.PoolDeltas[] memory deltas,
            uint160[] memory sqrtPriceX96AfterList,
            uint32[] memory initializedTicksLoadedList
        )
    {
        if (
            params.zeroForOnes.length != params.recipients.length || params.recipients.length != params.amountIns.length
                || params.amountIns.length != params.sqrtPriceLimitX96s.length
                || params.sqrtPriceLimitX96s.length != params.hookData.length
        ) {
            revert InvalidQuoteBatchParams();
        }

        deltas = new IQuoter.PoolDeltas[](params.amountIns.length);
        sqrtPriceX96AfterList = new uint160[](params.amountIns.length);
        initializedTicksLoadedList = new uint32[](params.amountIns.length);

        for (uint256 i = 0; i < params.amountIns.length; i++) {
            ExactInputSingleParams memory singleParams = ExactInputSingleParams({
                poolKey: params.poolKey,
                zeroForOne: params.zeroForOnes[i],
                recipient: params.recipients[i],
                amountIn: params.amountIns[i],
                sqrtPriceLimitX96: params.sqrtPriceLimitX96s[i],
                hookData: params.hookData[i]
            });
            (int128[] memory deltaAmounts, uint160 sqrtPriceX96After, uint32 initializedTicksLoaded) =
                quoteExactInputSingle(singleParams);

            deltas[i] = IQuoter.PoolDeltas({currency0Delta: deltaAmounts[0], currency1Delta: deltaAmounts[1]});
            sqrtPriceX96AfterList[i] = sqrtPriceX96After;
            initializedTicksLoadedList[i] = initializedTicksLoaded;
        }
    }

    /// @inheritdoc IQuoter
    function quoteExactOutputSingle(ExactOutputSingleParams memory params)
        public
        override
        returns (int128[] memory deltaAmounts, uint160 sqrtPriceX96After, uint32 initializedTicksLoaded)
    {
        try manager.lock(abi.encode(SwapInfo(SwapType.ExactOutputSingle, abi.encode(params)))) {}
        catch (bytes memory reason) {
            return _handleRevertSingle(reason, params.poolKey);
        }
    }

    /// @inheritdoc IQuoter
    function quoteExactOutput(ExactOutputParams memory params)
        public
        override
        returns (
            int128[] memory deltaAmounts,
            uint160[] memory sqrtPriceX96AfterList,
            uint32[] memory initializedTicksLoadedList
        )
    {
        try manager.lock(abi.encode(SwapInfo(SwapType.ExactOutput, abi.encode(params)))) {}
        catch (bytes memory reason) {
            return _handleRevert(reason);
        }
    }

    function quoteExactOutputBatch(ExactOutputSingleBatchParams memory params)
        external
        returns (
            IQuoter.PoolDeltas[] memory deltas,
            uint160[] memory sqrtPriceX96AfterList,
            uint32[] memory initializedTicksLoadedList
        )
    {
        if (
            params.zeroForOnes.length != params.recipients.length
                || params.recipients.length != params.amountOuts.length
                || params.amountOuts.length != params.sqrtPriceLimitX96s.length
                || params.sqrtPriceLimitX96s.length != params.hookData.length
        ) {
            revert InvalidQuoteBatchParams();
        }

        deltas = new IQuoter.PoolDeltas[](params.amountOuts.length);
        sqrtPriceX96AfterList = new uint160[](params.amountOuts.length);
        initializedTicksLoadedList = new uint32[](params.amountOuts.length);

        for (uint256 i = 0; i < params.amountOuts.length; i++) {
            ExactOutputSingleParams memory singleParams = ExactOutputSingleParams({
                poolKey: params.poolKey,
                zeroForOne: params.zeroForOnes[i],
                recipient: params.recipients[i],
                amountOut: params.amountOuts[i],
                sqrtPriceLimitX96: params.sqrtPriceLimitX96s[i],
                hookData: params.hookData[i]
            });
            (int128[] memory deltaAmounts, uint160 sqrtPriceX96After, uint32 initializedTicksLoaded) =
                quoteExactOutputSingle(singleParams);

            deltas[i] = IQuoter.PoolDeltas({currency0Delta: deltaAmounts[0], currency1Delta: deltaAmounts[1]});
            sqrtPriceX96AfterList[i] = sqrtPriceX96After;
            initializedTicksLoadedList[i] = initializedTicksLoaded;
        }
    }

    function lockAcquired(bytes calldata encodedSwapIntention) external returns (bytes memory) {
        if (msg.sender != address(manager)) {
            revert InvalidLockAcquiredSender();
        }

        SwapInfo memory swapInfo = abi.decode(encodedSwapIntention, (SwapInfo));
        bytes memory result;

        if (swapInfo.swapType == SwapType.ExactInputSingle) {
            (BalanceDelta deltas, uint160 sqrtPriceX96After, int24 tickAfter) =
                _quoteExactInputSingle(abi.decode(swapInfo.params, (ExactInputSingleParams)));

            result = abi.encode(deltas, sqrtPriceX96After, tickAfter);
        } else if (swapInfo.swapType == SwapType.ExactOutputSingle) {
            (BalanceDelta deltas, uint160 sqrtPriceX96After, int24 tickAfter) =
                _quoteExactOutputSingle(abi.decode(swapInfo.params, (ExactOutputSingleParams)));

            result = abi.encode(deltas, sqrtPriceX96After, tickAfter);
        } else if (swapInfo.swapType == SwapType.ExactInput) {
            (
                int128[] memory deltaAmounts,
                uint160[] memory sqrtPriceX96AfterList,
                uint32[] memory initializedTicksLoadedList
            ) = _quoteExactInput(abi.decode(swapInfo.params, (ExactInputParams)));

            result = abi.encode(deltaAmounts, sqrtPriceX96AfterList, initializedTicksLoadedList);
        } else if (swapInfo.swapType == SwapType.ExactOutput) {
            (
                int128[] memory deltaAmounts,
                uint160[] memory sqrtPriceX96AfterList,
                uint32[] memory initializedTicksLoadedList
            ) = _quoteExactOutput(abi.decode(swapInfo.params, (ExactOutputParams)));

            result = abi.encode(deltaAmounts, sqrtPriceX96AfterList, initializedTicksLoadedList);
        } else {
            revert InvalidQuoteType();
        }
        assembly {
            revert(add(0x20, result), mload(result))
        }
    }

    /// @dev check revert bytes and pass through if considered valid; otherwise revert with different message
    function validateRevertReason(bytes memory reason) private pure returns (bytes memory) {
        if (reason.length < MINIMUM_VALID_REASON_LENGTH) {
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
    function _handleRevertSingle(bytes memory reason, PoolKey memory poolKey)
        private
        view
        returns (int128[] memory deltaAmounts, uint160 sqrtPriceX96After, uint32 initializedTicksLoaded)
    {
        int24 tickBefore;
        int24 tickAfter;
        BalanceDelta deltas;
        deltaAmounts = new int128[](2);
        (, tickBefore,,) = manager.getSlot0(poolKey.toId());
        reason = validateRevertReason(reason);
        (deltas, sqrtPriceX96After, tickAfter) = abi.decode(reason, (BalanceDelta, uint160, int24));
        deltaAmounts[0] = deltas.amount0();
        deltaAmounts[1] = deltas.amount1();

        initializedTicksLoaded = PoolTicksCounter.countInitializedTicksLoaded(manager, poolKey, tickBefore, tickAfter);
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

    function _quoteExactInput(ExactInputParams memory params)
        private
        returns (
            int128[] memory deltaAmounts,
            uint160[] memory sqrtPriceX96AfterList,
            uint32[] memory initializedTicksLoadedList
        )
    {
        uint256 pathLength = params.path.length;

        deltaAmounts = new int128[](pathLength + 1);
        sqrtPriceX96AfterList = new uint160[](pathLength);
        initializedTicksLoadedList = new uint32[](pathLength);
        Currency prevCurrencyOut;
        uint128 prevAmountOut;

        for (uint256 i = 0; i < pathLength; i++) {
            (PoolKey memory poolKey, bool zeroForOne) =
                SwapIntention.getPoolAndSwapDirection(params.path[i], i == 0 ? params.currencyIn : prevCurrencyOut);
            (, int24 tickBefore,,) = manager.getSlot0(poolKey.toId());

            ExactInputSingleParams memory singleParams = ExactInputSingleParams({
                poolKey: poolKey,
                zeroForOne: zeroForOne,
                recipient: params.recipient,
                amountIn: i == 0 ? params.amountIn : prevAmountOut,
                sqrtPriceLimitX96: 0,
                hookData: params.path[i].hookData
            });
            (BalanceDelta curDeltas, uint160 sqrtPriceX96After, int24 tickAfter) = _quoteExactInputSingle(singleParams);

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
    }

    function _quoteExactInputSingle(ExactInputSingleParams memory params)
        private
        returns (BalanceDelta deltas, uint160 sqrtPriceX96After, int24 tickAfter)
    {
        return _swap(
            params.poolKey,
            params.zeroForOne,
            int256(int128(params.amountIn)),
            params.sqrtPriceLimitX96,
            params.hookData
        );
    }

    function _quoteExactOutput(ExactOutputParams memory params)
        private
        returns (
            int128[] memory deltaAmounts,
            uint160[] memory sqrtPriceX96AfterList,
            uint32[] memory initializedTicksLoadedList
        )
    {
        uint256 pathLength = params.path.length;

        deltaAmounts = new int128[](pathLength + 1);
        sqrtPriceX96AfterList = new uint160[](pathLength);
        initializedTicksLoadedList = new uint32[](pathLength);
        Currency prevCurrencyIn;
        uint128 prevAmountIn;

        for (uint256 i = pathLength; i > 0; i--) {
            (PoolKey memory poolKey, bool oneForZero) = SwapIntention.getPoolAndSwapDirection(
                params.path[i - 1], i == pathLength ? params.currencyOut : prevCurrencyIn
            );

            (, int24 tickBefore,,) = manager.getSlot0(poolKey.toId());

            ExactOutputSingleParams memory singleParams = ExactOutputSingleParams({
                poolKey: poolKey,
                zeroForOne: !oneForZero,
                recipient: params.recipient,
                amountOut: i == pathLength ? params.amountOut : prevAmountIn,
                sqrtPriceLimitX96: 0,
                hookData: params.path[i - 1].hookData
            });
            (BalanceDelta curDeltas, uint160 sqrtPriceX96After, int24 tickAfter) = _quoteExactOutputSingle(singleParams);

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
    }

    function _quoteExactOutputSingle(ExactOutputSingleParams memory params)
        private
        returns (BalanceDelta deltas, uint160 sqrtPriceX96After, int24 tickAfter)
    {
        return _swap(
            params.poolKey,
            params.zeroForOne,
            -int256(uint256(params.amountOut)),
            params.sqrtPriceLimitX96,
            params.hookData
        );
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
