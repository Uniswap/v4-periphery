// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Proxy} from "@openzeppelin/contracts/proxy/Proxy.sol";
import {BaseMiddleware} from "./BaseMiddleware.sol";
import {BaseHook} from "../BaseHook.sol";
import {BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";

abstract contract BaseRemove is BaseMiddleware {
    using TransientStateLibrary for IPoolManager;

    error HookPermissionForbidden(address hooks);
    error HookModifiedDeltas();
    error FailedImplementationCall();

    bytes internal constant ZERO_BYTES = bytes("");
    uint256 public constant GAS_LIMIT = 5_000_000;
    uint256 public constant MAX_BIPS = 10_000;

    // use this hookdata to override checks to save gas. keccak256("override") - 1
    bytes32 constant OVERRIDE_BYTES = 0x23b70c8dec38c3dec67a5596870027b04c4058cb3ac57b4e589bf628ac6669e7;

    uint256 public immutable maxFeeBips;

    constructor(IPoolManager _manager, address _impl) BaseMiddleware(_manager, _impl) {}

    function beforeRemoveLiquidity(
        address sender,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata params,
        bytes calldata hookData
    ) external returns (bytes4) {
        if (bytes32(hookData) == OVERRIDE_BYTES) {
            (, bytes memory returnData) = address(implementation).delegatecall(
                abi.encodeWithSelector(this.beforeRemoveLiquidity.selector, sender, key, params, hookData[32:])
            );
            return abi.decode(returnData, (bytes4));
        }
        address(this).delegatecall{gas: GAS_LIMIT}(
            abi.encodeWithSelector(this._beforeRemoveLiquidity.selector, msg.data)
        );
        return BaseHook.beforeRemoveLiquidity.selector;
    }

    function _beforeRemoveLiquidity(bytes calldata data) external {
        (bool success, bytes memory returnData) = address(implementation).delegatecall(data);
        if (!success) {
            revert FailedImplementationCall();
        }
        (bytes4 selector) = abi.decode(returnData, (bytes4));
        if (selector != BaseHook.beforeRemoveLiquidity.selector) {
            revert Hooks.InvalidHookResponse();
        }
        if (manager.getNonzeroDeltaCount() != 0) {
            revert HookModifiedDeltas();
        }
    }
}
