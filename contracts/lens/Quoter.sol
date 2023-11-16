// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.20;

import "forge-std/console2.sol";
import "../libraries/SwapIntention.sol";
import {IQuoter} from "../interfaces/IQuoter.sol";
import {PoolTicksCounter} from "../libraries/PoolTicksCounter.sol";
import {Hooks} from "@uniswap/v4-core/contracts/libraries/Hooks.sol";
import {SafeCast} from "@uniswap/v4-core/contracts/libraries/SafeCast.sol";
import {Pool} from "@uniswap/v4-core/contracts/libraries/Pool.sol";
import {TickMath} from "@uniswap/v4-core/contracts/libraries/TickMath.sol";
import {IHooks} from "@uniswap/v4-core/contracts/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/contracts/interfaces/IPoolManager.sol";
import {BalanceDelta} from "@uniswap/v4-core/contracts/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/contracts/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/contracts/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/contracts/types/PoolId.sol";
import {PoolManager} from "@uniswap/v4-core/contracts/PoolManager.sol";

contract Quoter is IQuoter {
    using PoolIdLibrary for PoolKey;
    using Hooks for IHooks;

    // v4 Singleton contract
    IPoolManager immutable poolManager;

    constructor(address _poolManager) {
        poolManager = IPoolManager(_poolManager);
    }

    function quoteExactInputSingle(ExactInputSingleParams memory params)
        external
        override
        returns (int128[] memory deltaAmounts, uint160 sqrtPriceX96After, uint32 initializedTicksCrossed)
    {
        try poolManager.lock(abi.encode(SwapInfo(SwapType.ExactInputSingle, abi.encode(params)))) {}
        catch (bytes memory reason) {
            return _handleRevertExactInputSingle(reason, params.poolKey);
        }
    }

    function quoteExactInput(ExactInputParams memory params)
        external
        returns (
            int128[] memory deltaAmounts,
            uint160[] memory sqrtPriceX96AfterList,
            uint32[] memory initializedTicksCrossedList
        )
    {
        try poolManager.lock(abi.encode(SwapInfo(SwapType.ExactInput, abi.encode(params)))) {}
        catch (bytes memory reason) {
            return _handleRevertExactInput(reason);
        }
    }

    function lockAcquired(bytes calldata encodedSwapIntention) external returns (bytes memory) {
        require(msg.sender == address(poolManager));

        SwapInfo memory swapInfo = abi.decode(encodedSwapIntention, (SwapInfo));

        if (swapInfo.swapType == SwapType.ExactInputSingle) {
            (BalanceDelta deltas, uint160 sqrtPriceX96After, int24 tickAfter) =
                _quoteExactInputSingle(abi.decode(swapInfo.params, (ExactInputSingleParams)));
            assembly {
                let ptr := mload(0x40)
                mstore(ptr, deltas)
                mstore(add(ptr, 0x20), sqrtPriceX96After)
                mstore(add(ptr, 0x40), tickAfter)
                revert(ptr, 96)
            }
        } else if (swapInfo.swapType == SwapType.ExactInput) {
            (
                int128[] memory deltaAmounts,
                uint160[] memory sqrtPriceX96AfterList,
                uint32[] memory initializedTicksCrossedList
            ) = _quoteExactInput(abi.decode(swapInfo.params, (ExactInputParams)));

            assembly {
                // function storeArray(offset, length, array) {
                //     mstore(offset, length)
                //     offset := add(offset, 0x20)
                //     for { let i := 0 } lt(i, length) { i := add(i, 1) } {
                //         let value := mload(add(array, add(mul(i, 0x20), 0x20)))
                //         mstore(offset, value)
                //         offset := add(offset, 0x20)
                //     }
                // }

                let originalPtr := mload(0x40)
                let ptr := mload(0x40)

                let deltaLength := mload(deltaAmounts)
                let sqrtPriceLength := mload(sqrtPriceX96AfterList)
                let initializedTicksLength := mload(initializedTicksCrossedList)

                let deltaOffset := 0x60
                let sqrtPriceOffset := add(deltaOffset, add(0x20, mul(0x20, deltaLength)))
                let initializedTicksOffset := add(sqrtPriceOffset, add(0x20, mul(0x20, sqrtPriceLength)))

                // storing offsets to dynamic arrays
                mstore(ptr, deltaOffset)
                ptr := add(ptr, 0x20)
                mstore(ptr, sqrtPriceOffset)
                ptr := add(ptr, 0x20)
                mstore(ptr, initializedTicksOffset)
                ptr := add(ptr, 0x20)

                //storing length + contents of dynamic arrays
                mstore(ptr, deltaLength)
                ptr := add(ptr, 0x20)
                for { let i := 0 } lt(i, deltaLength) { i := add(i, 1) } {
                    let value := mload(add(deltaAmounts, add(mul(i, 0x20), 0x20)))
                    mstore(ptr, value)
                    ptr := add(ptr, 0x20)
                }

                mstore(ptr, sqrtPriceLength)
                ptr := add(ptr, 0x20)
                for { let i := 0 } lt(i, sqrtPriceLength) { i := add(i, 1) } {
                    let value := mload(add(sqrtPriceX96AfterList, add(mul(i, 0x20), 0x20)))
                    mstore(ptr, value)
                    ptr := add(ptr, 0x20)
                }

                mstore(ptr, initializedTicksLength)
                ptr := add(ptr, 0x20)
                for { let i := 0 } lt(i, initializedTicksLength) { i := add(i, 1) } {
                    let value := mload(add(initializedTicksCrossedList, add(mul(i, 0x20), 0x20)))
                    mstore(ptr, value)
                    ptr := add(ptr, 0x20)
                }

                revert(originalPtr, sub(ptr, originalPtr))
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

    function _handleRevertExactInputSingle(bytes memory reason, PoolKey memory poolKey)
        private
        view
        returns (int128[] memory deltaAmounts, uint160 sqrtPriceX96After, uint32 initializedTicksCrossed)
    {
        int24 tickBefore;
        int24 tickAfter;
        BalanceDelta deltas;
        deltaAmounts = new int128[](2);
        (, tickBefore,,) = poolManager.getSlot0(poolKey.toId());
        reason = validateRevertReason(reason);
        (deltas, sqrtPriceX96After, tickAfter) = abi.decode(reason, (BalanceDelta, uint160, int24));
        deltaAmounts[0] = deltas.amount0();
        deltaAmounts[1] = deltas.amount1();

        initializedTicksCrossed =
            PoolTicksCounter.countInitializedTicksCrossed(poolManager, poolKey, tickBefore, tickAfter);
    }

    function _handleRevertExactInput(bytes memory reason)
        private
        pure
        returns (
            int128[] memory deltaAmounts,
            uint160[] memory sqrtPriceX96AfterList,
            uint32[] memory initializedTicksCrossedList
        )
    {
        reason = validateRevertReason(reason);
        (deltaAmounts, sqrtPriceX96AfterList, initializedTicksCrossedList) =
            abi.decode(reason, (int128[], uint160[], uint32[]));
    }

    function _quoteExactInput(ExactInputParams memory params)
        private
        returns (
            int128[] memory deltaAmounts,
            uint160[] memory sqrtPriceX96AfterList,
            uint32[] memory initializedTicksCrossedList
        )
    {
        uint256 pathLength = params.path.length;

        deltaAmounts = new int128[](pathLength + 1);
        sqrtPriceX96AfterList = new uint160[](pathLength);
        initializedTicksCrossedList = new uint32[](pathLength);
        Currency prevCurrencyOut;
        uint128 prevAmountOut;

        for (uint256 i = 0; i < pathLength; i++) {
            (PoolKey memory poolKey, bool zeroForOne) =
                SwapIntention.getPoolAndSwapDirection(params.path[i], i == 0 ? params.currencyIn : prevCurrencyOut);
            (, int24 tickBefore,,) = poolManager.getSlot0(poolKey.toId());

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
            initializedTicksCrossedList[i] =
                PoolTicksCounter.countInitializedTicksCrossed(poolManager, poolKey, tickBefore, tickAfter);
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

    function _quoteExact(
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
                sqrtPriceLimitX96: sqrtPriceLimitX96 == 0
                    ? zeroForOne ? TickMath.MIN_SQRT_RATIO + 1 : TickMath.MAX_SQRT_RATIO - 1
                    : sqrtPriceLimitX96
            }),
            hookData
        );
        (sqrtPriceX96After, tickAfter,,) = poolManager.getSlot0(poolKey.toId());
    }
}
