// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.20;

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
        returns (uint256 amount, uint160 sqrtPriceX96After, int24 tickAfter)
    {
        if (reason.length != 96) {
            if (reason.length < 68) {
                revert UnexpectedRevertBytes();
            }
            assembly {
                reason := add(reason, 0x04)
            }
            revert(abi.decode(reason, (string)));
        }
        return abi.decode(reason, (uint256, uint160, int24));
    }

    function handleRevert(bytes memory reason, PoolKey memory poolKey)
        private
        view
        returns (uint256 amount, uint160 sqrtPriceX96After, uint32 initializedTicksCrossed)
    {
        int24 tickBefore;
        int24 tickAfter;
        (, tickBefore,,) = poolManager.getSlot0(poolKey.toId());
        (amount, sqrtPriceX96After, tickAfter) = parseRevertReason(reason);

        initializedTicksCrossed =
            PoolTicksCounter.countInitializedTicksCrossed(poolManager, poolKey, tickBefore, tickAfter);

        return (amount, sqrtPriceX96After, initializedTicksCrossed);
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
        returns (uint256 amountOut, uint160 sqrtPriceX96After, uint32 initializedTicksCrossed)
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
    function _quoteExactInputSingle(ExactInputSingleParams memory params)
        private
        returns (uint256 amountOut, uint160 sqrtPriceX96After, int24 tickAfter)
    {
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

        (sqrtPriceX96After, tickAfter,,) = poolManager.getSlot0(params.poolKey.toId());
        if (params.zeroForOne) {
            amountOut = uint128(-delta.amount1());
        } else {
            amountOut = uint128(-delta.amount0());
        }

        assembly {
            let ptr := mload(0x40)
            mstore(ptr, amountOut)
            mstore(add(ptr, 0x20), sqrtPriceX96After)
            mstore(add(ptr, 0x40), tickAfter)
            revert(ptr, 96)
        }
    }
}
