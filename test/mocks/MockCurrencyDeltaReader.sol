// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {CurrencySettler} from "@uniswap/v4-core/test/utils/CurrencySettler.sol";

import {CurrencyDeltas} from "../../src/libraries/CurrencyDeltas.sol";

/// @dev A minimal helper strictly for testing
contract MockCurrencyDeltaReader {
    using TransientStateLibrary for IPoolManager;
    using CurrencyDeltas for IPoolManager;
    using CurrencySettler for Currency;

    IPoolManager public poolManager;

    address sender;

    constructor(IPoolManager _poolManager) {
        poolManager = _poolManager;
    }

    /// @param calls an array of abi.encodeWithSelector
    function execute(bytes[] calldata calls, Currency currency0, Currency currency1) external returns (BalanceDelta) {
        sender = msg.sender;
        return abi.decode(poolManager.unlock(abi.encode(calls, currency0, currency1)), (BalanceDelta));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        (bytes[] memory calls, Currency currency0, Currency currency1) = abi.decode(data, (bytes[], Currency, Currency));
        for (uint256 i; i < calls.length; i++) {
            (bool success,) = address(this).call(calls[i]);
            if (!success) revert("CurrencyDeltaReader");
        }

        BalanceDelta delta = poolManager.currencyDeltas(address(this), currency0, currency1);
        int256 delta0 = poolManager.currencyDelta(address(this), currency0);
        int256 delta1 = poolManager.currencyDelta(address(this), currency1);

        // confirm agreement between currencyDeltas and single-read currencyDelta
        require(delta.amount0() == int128(delta0), "CurrencyDeltaReader: delta0");
        require(delta.amount1() == int128(delta1), "CurrencyDeltaReader: delta1");

        // close deltas
        if (delta.amount0() < 0) currency0.settle(poolManager, sender, uint256(-int256(delta.amount0())), false);
        if (delta.amount1() < 0) currency1.settle(poolManager, sender, uint256(-int256(delta.amount1())), false);
        if (delta.amount0() > 0) currency0.take(poolManager, sender, uint256(int256(delta.amount0())), false);
        if (delta.amount1() > 0) currency1.take(poolManager, sender, uint256(int256(delta.amount1())), false);
        return abi.encode(delta);
    }

    function settle(Currency currency, uint256 amount) external {
        currency.settle(poolManager, sender, amount, false);
    }

    function burn(Currency currency, uint256 amount) external {
        currency.settle(poolManager, sender, amount, true);
    }

    function take(Currency currency, uint256 amount) external {
        currency.take(poolManager, sender, amount, false);
    }

    function mint(Currency currency, uint256 amount) external {
        currency.take(poolManager, sender, amount, true);
    }
}
