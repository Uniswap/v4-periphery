// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.20;

import "../libraries/SwapIntention.sol";
import {IQuoter} from "../interfaces/IQuoter.sol";
import {PoolTicksCounter} from "../libraries/PoolTicksCounter.sol";
import {Hooks} from "@uniswap/v4-core/contracts/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/contracts/libraries/TickMath.sol";
import {IHooks} from "@uniswap/v4-core/contracts/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/contracts/interfaces/IPoolManager.sol";
import {BalanceDelta} from "@uniswap/v4-core/contracts/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/contracts/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/contracts/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/contracts/types/PoolId.sol";

contract Quoter is IQuoter {
    using PoolIdLibrary for PoolKey;
    using Hooks for IHooks;

    /// @dev Transient storage variable used to check a safety condition in exact output swaps.
    uint256 private amountOutCached;

    // v4 Singleton contract
    IPoolManager public immutable manager;

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
            return _handleRevertExactInput(reason);
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

    function lockAcquired(bytes calldata encodedSwapIntention) external returns (bytes memory) {
        if (msg.sender != address(manager)) {
            revert InvalidLockAcquiredSender();
        }

        SwapInfo memory swapInfo = abi.decode(encodedSwapIntention, (SwapInfo));

        if (swapInfo.swapType == SwapType.ExactInputSingle) {
            (BalanceDelta deltas, uint160 sqrtPriceX96After, int24 tickAfter) =
                _quoteExactInputSingle(abi.decode(swapInfo.params, (ExactInputSingleParams)));

            bytes memory result = abi.encode(deltas, sqrtPriceX96After, tickAfter);
            assembly {
                revert(add(0x20, result), mload(result))
            }
        } else if (swapInfo.swapType == SwapType.ExactOutputSingle) {
            (BalanceDelta deltas, uint160 sqrtPriceX96After, int24 tickAfter) =
                _quoteExactOutputSingle(abi.decode(swapInfo.params, (ExactOutputSingleParams)));

            bytes memory result = abi.encode(deltas, sqrtPriceX96After, tickAfter);
            assembly {
                revert(add(0x20, result), mload(result))
            }
        } else if (swapInfo.swapType == SwapType.ExactInput) {
            (
                int128[] memory deltaAmounts,
                uint160[] memory sqrtPriceX96AfterList,
                uint32[] memory initializedTicksLoadedList
            ) = _quoteExactInput(abi.decode(swapInfo.params, (ExactInputParams)));

            bytes memory result = abi.encode(deltaAmounts, sqrtPriceX96AfterList, initializedTicksLoadedList);
            assembly {
                revert(add(0x20, result), mload(result))
            }
        } else {
            revert InvalidQuoteType();
        }
    }

    function validateRevertReason(bytes memory reason) private pure returns (bytes memory) {
        if (reason.length < 96) {
            // function selector + length of bytes as uint256 + min length of revert reason padded to multiple of 32 bytes
            if (reason.length < 68) {
                revert UnexpectedRevertBytes();
            }
            assembly {
                reason := add(reason, 0x04)
            }
            revert(abi.decode(reason, (string)));
        }
        return reason;
    }

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

    function _handleRevertExactInput(bytes memory reason)
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
        return _quoteExact(
            params.poolKey,
            params.zeroForOne,
            int256(int128(params.amountIn)),
            params.sqrtPriceLimitX96,
            params.hookData
        );
    }

    function _quoteExactOutputSingle(ExactOutputSingleParams memory params)
        private
        returns (BalanceDelta deltas, uint160 sqrtPriceX96After, int24 tickAfter)
    {
        return _quoteExact(
            params.poolKey,
            params.zeroForOne,
            -int256(int128(params.amountOut)),
            params.sqrtPriceLimitX96,
            params.hookData
        );
    }

    function _quoteExact(
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

    function _sqrtPriceLimitOrDefault(uint160 sqrtPriceLimitX96, bool zeroForOne) private pure returns (uint160) {
        return sqrtPriceLimitX96 == 0
            ? zeroForOne ? TickMath.MIN_SQRT_RATIO + 1 : TickMath.MAX_SQRT_RATIO - 1
            : sqrtPriceLimitX96;
    }
}
