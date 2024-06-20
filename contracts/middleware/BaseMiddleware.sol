// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {Proxy} from "@openzeppelin/contracts/proxy/Proxy.sol";
import {console} from "../../lib/forge-std/src/console.sol";

contract BaseMiddleware is Proxy {
    /// @notice The address of the pool manager
    IPoolManager public immutable poolManager;
    address public immutable implementation;

    constructor(IPoolManager _poolManager, address _impl) {
        poolManager = _poolManager;
        implementation = _impl;
    }

    function _implementation() internal view override returns (address) {
        console.logAddress(implementation);
        return implementation;
    }

    receive() external payable {
        // ??
    }
}
