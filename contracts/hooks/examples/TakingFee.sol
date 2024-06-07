// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseHook} from "../../BaseHook.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import {Owned} from "solmate/auth/Owned.sol";

contract TakingFee is BaseHook, Owned {
    using PoolIdLibrary for PoolKey;
    using SafeCast for uint256;

    uint128 private constant TOTAL_BIPS = 10000;
    uint128 private constant MAX_BIPS = 100;
    uint128 public swapFeeBips;
    address public treasury = msg.sender;

    constructor(
        IPoolManager _poolManager,
        uint128 _swapFeeBips,
        address _treasury
    ) BaseHook(_poolManager) Owned(msg.sender) {
        swapFeeBips = _swapFeeBips;
        treasury = _treasury;
    }

    function getHookPermissions()
        public
        pure
        override
        returns (Hooks.Permissions memory)
    {
        return
            Hooks.Permissions({
                beforeInitialize: false,
                afterInitialize: false,
                beforeAddLiquidity: false,
                afterAddLiquidity: false,
                beforeRemoveLiquidity: false,
                afterRemoveLiquidity: false,
                beforeSwap: false,
                afterSwap: true,
                beforeDonate: false,
                afterDonate: false,
                beforeSwapReturnDelta: false,
                afterSwapReturnDelta: true,
                afterAddLiquidityReturnDelta: false,
                afterRemoveLiquidityReturnDelta: false
            });
    }

    function afterSwap(
        address,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata
    ) external override returns (bytes4, int128) {
        // fee will be in the unspecified token of the swap
        bool specifiedTokenIs0 = (params.amountSpecified < 0 ==
            params.zeroForOne);
        (Currency feeCurrency, int128 swapAmount) = (specifiedTokenIs0)
            ? (key.currency1, delta.amount1())
            : (key.currency0, delta.amount0());
        // if fee is on output, get the absolute output amount
        if (swapAmount < 0) swapAmount = -swapAmount;

        uint256 feeAmount = (uint128(swapAmount) * swapFeeBips) / TOTAL_BIPS;
        poolManager.take(feeCurrency, treasury, feeAmount);

        return (BaseHook.afterSwap.selector, feeAmount.toInt128());
    }

    function setSwapFeeBips(uint128 _swapFeeBips) external onlyOwner {
        require(_swapFeeBips <= MAX_BIPS);
        swapFeeBips = _swapFeeBips;
    }

    function setTreasury(address _treasury) external onlyOwner {
        treasury = _treasury;
    }
}
