// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Proxy} from "@openzeppelin/contracts/proxy/Proxy.sol";

/**
 * @notice Proxy contract that forwards calls to an implementation contract.
 * @dev Inheret this contract and implement hook functions to create a middleware.
 */
abstract contract BaseMiddleware is Proxy {
    /// @notice The address of the pool manager
    /// @dev Use in middleware implementations to access the pool manager
    IPoolManager public immutable poolManager;

    /// @notice The address of the implementation contract. All calls to this contract will be forwarded to implementation.
    address public immutable implementation;

    error FlagsMismatch();

    constructor(IPoolManager _poolManager, address _impl) {
        poolManager = _poolManager;
        implementation = _impl;
    }

    function _implementation() internal view override returns (address) {
        return implementation;
    }

    // DELETE THIS
    receive() external payable {}
}
