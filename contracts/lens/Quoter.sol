// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.20;

import "forge-std/console.sol";
import {IQuoter} from "../interfaces/IQuoter.sol";
import {PoolTicksCounter} from "../libraries/PoolTicksCounter.sol";
import {SwapInfo, SwapType, ExactInputSingleParams} from "../libraries/SwapIntention.sol";
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

    /*
    struct QuoteCallBackData {
        address swapper;
        PoolKey key;
        IPoolManager.SwapParams params;
        bytes hookData;
    }
    struct QuoteExactInputSingleParams {
        address swapper;
        Currency tokenIn;
        Currency tokenOut;
        PoolKey poolKey;
        uint256 amountIn;
        uint160 sqrtPriceLimitX96;
        bytes hookData;
    }
    struct SwapParams {
        int24 tickSpacing;
        bool zeroForOne;
        int256 amountSpecified;
        uint160 sqrtPriceLimitX96;
    }
    */
    function parseRevertReason(bytes memory reason)
        private
        pure
        returns (int128 amount0Delta, int128 amount1Delta, uint160 sqrtPriceX96After, int24 tickAfter)
    {
        if (reason.length != 128) {
            // function selector + length of bytes as uint256 + min length of revert reason padded to multiple of 32 bytes
            if (reason.length < 68) {
                revert UnexpectedRevertBytes();
            }
            assembly {
                reason := add(reason, 0x04)
            }
            revert(abi.decode(reason, (string)));
        }
        (int256 _amount0Delta, int256 _amount1Delta, uint160 _sqrtPriceX96After, int24 _tickAfter) =
            abi.decode(reason, (int128, int128, uint160, int24));
        amount0Delta = _amount0Delta.toInt128();
        amount1Delta = _amount1Delta.toInt128();
        sqrtPriceX96After = _sqrtPriceX96After;
        tickAfter = _tickAfter;
    }

    function handleRevert(bytes memory reason, PoolKey memory poolKey)
        private
        view
        returns (int128 amount0Delta, int128 amount1Delta, uint160 sqrtPriceX96After, uint32 initializedTicksCrossed)
    {
        int24 tickBefore;
        int24 tickAfter;
        (, tickBefore,,) = poolManager.getSlot0(poolKey.toId());
        (amount0Delta, amount1Delta, sqrtPriceX96After, tickAfter) = parseRevertReason(reason);

        initializedTicksCrossed =
            PoolTicksCounter.countInitializedTicksCrossed(poolManager, poolKey, tickBefore, tickAfter);

        return (amount0Delta, amount1Delta, sqrtPriceX96After, initializedTicksCrossed);
    }

    function lockAcquired(bytes calldata encodedSwapIntention) external returns (bytes memory) {
        require(msg.sender == address(poolManager));

        SwapInfo memory swapInfo = abi.decode(encodedSwapIntention, (SwapInfo));

        if (swapInfo.swapType == SwapType.ExactInputSingle) {
            _quoteExactInputSingle(abi.decode(swapInfo.params, (ExactInputSingleParams)));
        } else {
            revert InvalidQuoteType();
        }
    }

    /*
    struct SwapInfo {
        SwapType swapType;
        address swapper;
        bytes params;
    }
    struct ExactInputSingleParams {
        PoolKey poolKey;
        bool zeroForOne;
        address recipient;
        uint128 amountIn;
        uint160 sqrtPriceLimitX96;
        bytes hookData;
    }
    */
    function quoteExactInputSingle(ExactInputSingleParams memory params)
        external
        override
        returns (int128 amount0Delta, int128 amount1Delta, uint160 sqrtPriceX96After, uint32 initializedTicksCrossed)
    {
        try poolManager.lock(abi.encode(SwapInfo(SwapType.ExactInputSingle, abi.encode(params)))) {}
        catch (bytes memory reason) {
            return handleRevert(reason, params.poolKey);
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
    function _quoteExactInputSingle(ExactInputSingleParams memory params) private {
        BalanceDelta delta = poolManager.swap(
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

        (uint160 sqrtPriceX96After, int24 tickAfter,,) = poolManager.getSlot0(params.poolKey.toId());
        int256 amount0Delta = int256(delta.amount0());
        int256 amount1Delta = int256(delta.amount1());
        // if (params.zeroForOne) {
        //     amountOut = uint128(-delta.amount1());
        // } else {
        //     amountOut = uint128(-delta.amount0());
        // }

        assembly {
            let ptr := mload(0x40)
            mstore(ptr, amount0Delta)
            mstore(add(ptr, 0x20), amount1Delta)
            mstore(add(ptr, 0x40), sqrtPriceX96After)
            mstore(add(ptr, 0x60), tickAfter)
            revert(ptr, 128)
        }
    }
}
