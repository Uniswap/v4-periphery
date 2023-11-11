// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.20;

import "forge-std/console.sol";
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
    using SafeCast for *;
    using Hooks for IHooks;

    // v4 Singleton contract
    IPoolManager poolManager;

    constructor(address _poolManager) {
        poolManager = IPoolManager(_poolManager);
    }

    function fillSlot0(PoolId id) private view returns (Pool.Slot0 memory slot0) {
        //TODO: extsload when storage is stable
        (slot0.sqrtPriceX96, slot0.tick,,) = poolManager.getSlot0(id);

        return slot0;
    }

    function parseRevertReason(bytes memory reason)
        private
        pure
        returns (BalanceDelta deltas, uint160 sqrtPriceX96After, int24 tickAfter)
    {
        if (reason.length != 96) {
            // function selector + length of bytes as uint256 + min length of revert reason padded to multiple of 32 bytes
            if (reason.length < 68) {
                revert UnexpectedRevertBytes();
            }
            assembly {
                reason := add(reason, 0x04)
            }
            revert(abi.decode(reason, (string)));
        }
        return abi.decode(reason, (BalanceDelta, uint160, int24));
    }

    function handleRevert(bytes memory reason, PoolKey memory poolKey)
        private
        view
        returns (BalanceDelta deltas, uint160 sqrtPriceX96After, uint32 initializedTicksCrossed)
    {
        int24 tickBefore;
        int24 tickAfter;
        (, tickBefore,,) = poolManager.getSlot0(poolKey.toId());
        (deltas, sqrtPriceX96After, tickAfter) = parseRevertReason(reason);

        initializedTicksCrossed =
            PoolTicksCounter.countInitializedTicksCrossed(poolManager, poolKey, tickBefore, tickAfter);
    }

    function lockAcquired(bytes calldata encodedSwapIntention) external returns (bytes memory) {
        require(msg.sender == address(poolManager));

        SwapInfo memory swapInfo = abi.decode(encodedSwapIntention, (SwapInfo));

        if (swapInfo.swapType == SwapType.ExactInputSingle) {
            (BalanceDelta deltas, uint160 sqrtPriceX96After, int24 tickAfter) =
                _quoteExactInputSingle(abi.decode(swapInfo.params, (ExactInputSingleParams)));
            console.logInt(deltas.amount0());
            assembly {
                let ptr := mload(0x40)
                mstore(ptr, deltas)
                mstore(add(ptr, 0x20), sqrtPriceX96After)
                mstore(add(ptr, 0x40), tickAfter)
                revert(ptr, 96)
            }
            // } else if (swapInfo.swapType == SwapType.ExactInput) {
            //     _quoteExactInput(abi.decode(swapInfo.params, (ExactInputParams)));
        } else {
            revert InvalidQuoteType();
        }
    }

    function quoteExactInputSingle(ExactInputSingleParams memory params)
        external
        override
        returns (BalanceDelta deltas, uint160 sqrtPriceX96After, uint32 initializedTicksCrossed)
    {
        try poolManager.lock(abi.encode(SwapInfo(SwapType.ExactInputSingle, abi.encode(params)))) {}
        catch (bytes memory reason) {
            return handleRevert(reason, SwapType.ExactInSingle, params.poolKey);
        }
    }

    function quoteExactInput(ExactInputParams memory params)
        external
        override
        returns (int128[] deltaAmounts, uint160[] sqrtPriceX96AfterList, uint32[] initializedTicksCrossedList)
    {
        try poolManager.lock(abi.encode(SwapInfo(SwapType.ExactInput, abi.encode(params)))) {}
        catch (bytes memory reason) {
            return handleRevert(reason, params.poolKey);
        }
    }

    function _quoteExactInput(ExactInputParams memory params)
        private
        returns (
            BalanceDelta[] memory deltaAmounts,
            uint160[] memory sqrtPriceX96AfterList,
            uint32[] memory initializedTicksCrossedList
        )
    {
        uint256 pathLength = params.path.length;
        BalanceDelta prevDeltas;
        boolean prevZeroForOne;

        deltaAmounts = new BalanceDelta[](pathLength);
        sqrtPriceX96AfterList = new uint160[](pathLength);
        initializedTicksCrossedList = new uint32[](pathLength);

        for (uint256 i = 0; i < pathLength; i++) {
            (PoolKey memory poolKey, bool zeroForOne) = SwapIntention.getPoolAndSwapDirection(
                params.path[i], i == 0 ? params.currencyIn : params.path[i - 1].intermediateCurrency
            );

            int128 curAmountIn =
                i == 0 ? params.amountIn : (prevZeroForOne ? -prevDeltas.amount1() : -prevDeltas.amount0());

            ExactInputSingleParams memory singleParams = ExactInputSingleParams({
                poolKey: poolKey,
                zeroForOne: zeroForOne,
                recipient: params.recipient,
                amountIn: cureAmountIn,
                sqrtPriceLimitX96: 0,
                hookData: params.path[i].hookData
            });
            (BalanceDelta curDeltas, uint160 sqrtPriceX96After, int24 tickAfter) = _quoteExactInputSingle(params);

            sqrtPriceX96AfterList[i] = sqrtPriceX96After;
            tickAfterList
        }
    }

    /*
    struct PathKey {
        Currency intermediateCurrency;
        uint24 fee;
        int24 tickSpacing;
        IHooks hooks;
        bytes hookData;
    }

    struct ExactInputSingleParams {
        PoolKey poolKey;
        bool zeroForOne;
        address recipient;
        uint128 amountIn;
        uint160 sqrtPriceLimitX96;
        bytes hookData;
    }

    struct IPoolManager.SwapParams {
        bool zeroForOne;
        int256 amountSpecified;
        uint160 sqrtPriceLimitX96;
    }
    */
    function _quoteExactInputSingle(ExactInputSingleParams memory params)
        private
        returns (BalanceDelta deltas, uint160 sqrtPriceX96After, int24 tickAfter)
    {
        deltas = poolManager.swap(
            params.poolKey,
            IPoolManager.SwapParams({
                zeroForOne: params.zeroForOne,
                amountSpecified: int256(int128(params.amountIn)),
                sqrtPriceLimitX96: params.sqrtPriceLimitX96 == 0
                    ? params.zeroForOne ? TickMath.MIN_SQRT_RATIO + 1 : TickMath.MAX_SQRT_RATIO - 1
                    : params.sqrtPriceLimitX96
            }),
            params.hookData
        );

        (sqrtPriceX96After, tickAfter,,) = poolManager.getSlot0(params.poolKey.toId());
    }
}
