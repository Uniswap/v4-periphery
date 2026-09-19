// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseTestHooks} from "@uniswap/v4-core/src/test/BaseTestHooks.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {CurrencySettler} from "@uniswap/v4-core/test/utils/CurrencySettler.sol";

/// @notice Returns a configured after-swap delta on the unspecified currency, settling or taking the matching amount.
///         It can also fund an exact-output input completely, with an optional additional amount.
contract MockArbitraryAfterSwapDeltaHook is BaseTestHooks {
    using CurrencySettler for Currency;

    IPoolManager public immutable manager;

    bool public subsidizeExactOutput;
    bool public forceInputDeltaToMin;
    int128 public fixedUnspecifiedDelta;
    uint128 public extraWei;

    constructor(IPoolManager _manager) {
        manager = _manager;
    }

    modifier onlyPoolManager() {
        require(msg.sender == address(manager), "not manager");
        _;
    }

    function setFixedUnspecifiedDelta(int128 _fixedUnspecifiedDelta) external {
        subsidizeExactOutput = false;
        forceInputDeltaToMin = false;
        fixedUnspecifiedDelta = _fixedUnspecifiedDelta;
    }

    function setSubsidizeExactOutput(uint128 _extraWei) external {
        subsidizeExactOutput = true;
        forceInputDeltaToMin = false;
        extraWei = _extraWei;
    }

    function setForceInputDeltaToMin() external {
        subsidizeExactOutput = false;
        forceInputDeltaToMin = true;
    }

    function afterSwap(
        address, /* sender */
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata /* hookData */
    )
        external
        override
        onlyPoolManager
        returns (bytes4, int128)
    {
        Currency unspecifiedCurrency = params.zeroForOne == (params.amountSpecified < 0) ? key.currency1 : key.currency0;

        int128 hookDelta = fixedUnspecifiedDelta;
        bool settleHookDelta = true;
        if (subsidizeExactOutput) {
            require(params.amountSpecified > 0, "exact output only");
            int128 inputDelta = params.zeroForOne ? delta.amount0() : delta.amount1();
            uint256 amount = uint256(-int256(inputDelta)) + extraWei;
            require(amount <= uint256(uint128(type(int128).max)), "subsidy overflows int128");
            hookDelta = -int128(int256(amount));
        } else if (forceInputDeltaToMin) {
            require(params.amountSpecified > 0, "exact output only");
            int128 inputDelta = params.zeroForOne ? delta.amount0() : delta.amount1();
            hookDelta = int128(int256(inputDelta) - int256(type(int128).min));
            // The quoter reverts the simulation before PoolManager checks unlock solvency. Avoid taking this
            // deliberately enormous hook credit so the test can reach the caller's int128 minimum delta.
            settleHookDelta = false;
        }

        if (settleHookDelta && hookDelta > 0) {
            unspecifiedCurrency.take(manager, address(this), uint128(hookDelta), false);
        } else if (settleHookDelta && hookDelta < 0) {
            unspecifiedCurrency.settle(manager, address(this), uint256(-int256(hookDelta)), false);
        }

        return (IHooks.afterSwap.selector, hookDelta);
    }
}
