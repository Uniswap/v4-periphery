// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {Proxy} from "@openzeppelin/contracts/proxy/Proxy.sol";

contract BaseMiddleware is Proxy {
    /// @notice The address of the pool manager
    IPoolManager public immutable manager;
    address public immutable implementation;

    error FlagsMismatch();

    constructor(IPoolManager _manager, address _impl) {
        _ensureValidFlags(_impl);
        manager = _manager;
        implementation = _impl;
    }

    function _implementation() internal view override returns (address) {
        return implementation;
    }

    function _ensureValidFlags(address _impl) internal view virtual {
        if (uint160(address(this)) & Hooks.ALL_HOOK_MASK != uint160(_impl) & Hooks.ALL_HOOK_MASK) {
            revert FlagsMismatch();
        }
    }
}
