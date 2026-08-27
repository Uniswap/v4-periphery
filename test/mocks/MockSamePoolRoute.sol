// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";

interface IERC20Min {
    function transfer(address to, uint256 amt) external returns (bool);
}

/// @notice A route that swaps in the target pool, like a Universal Router v4 leg through the same pool.
contract MockSamePoolRoute {
    using CurrencyLibrary for Currency;

    IPoolManager public immutable manager;
    IAllowanceTransfer public immutable permit2;

    PoolKey internal key;
    bool internal zeroForOne;
    uint256 internal inputAmount;

    constructor(IPoolManager _manager, IAllowanceTransfer _permit2) {
        manager = _manager;
        permit2 = _permit2;
    }

    function config(PoolKey memory k, bool z, uint256 amt) external {
        key = k;
        zeroForOne = z;
        inputAmount = amt;
    }

    function execute(bytes calldata, bytes[] calldata) external payable {
        Currency cIn = zeroForOne ? key.currency0 : key.currency1;
        Currency cOut = zeroForOne ? key.currency1 : key.currency0;
        permit2.transferFrom(msg.sender, address(this), uint160(inputAmount), Currency.unwrap(cIn));

        BalanceDelta d = manager.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(inputAmount),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            ""
        );
        int128 inDelta = zeroForOne ? d.amount0() : d.amount1();
        int128 outDelta = zeroForOne ? d.amount1() : d.amount0();

        manager.sync(cIn);
        IERC20Min(Currency.unwrap(cIn)).transfer(address(manager), uint256(uint128(-inDelta)));
        manager.settle();
        manager.take(cOut, msg.sender, uint256(uint128(outDelta)));
    }
}
