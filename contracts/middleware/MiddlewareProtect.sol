// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Proxy} from "@openzeppelin/contracts/proxy/Proxy.sol";
import {BaseHook} from "../BaseHook.sol";
import {BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {NonZeroDeltaCount} from "@uniswap/v4-core/src/libraries/NonZeroDeltaCount.sol";
import {IExttload} from "@uniswap/v4-core/src/interfaces/IExttload.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {MiddlewareRemove} from "./MiddlewareRemove.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {console} from "./../../lib/forge-gas-snapshot/lib/forge-std/src/console.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

contract MiddlewareProtect is MiddlewareRemove {
    using CustomRevert for bytes4;
    using Hooks for IHooks;
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;
    using BeforeSwapDeltaLibrary for BeforeSwapDelta;
    using LPFeeLibrary for uint24;
    using BalanceDeltaLibrary for BalanceDelta;

    error ForbiddenDynamicFee();
    error HookModifiedOutput();

    // todo: use tstore
    BalanceDelta private quote;

    uint160 public constant MIN_PRICE_LIMIT = TickMath.MIN_SQRT_PRICE + 1;
    uint160 public constant MAX_PRICE_LIMIT = TickMath.MAX_SQRT_PRICE - 1;

    constructor(IPoolManager _manager, address _impl) MiddlewareRemove(_manager, _impl) {
        IHooks middleware = IHooks(address(this));
        if (
            middleware.hasPermission(Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG)
                || middleware.hasPermission(Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG)
                || middleware.hasPermission(Hooks.AFTER_ADD_LIQUIDITY_RETURNS_DELTA_FLAG)
        ) {
            HookPermissionForbidden.selector.revertWith(address(this));
        }
    }

    function beforeInitialize(address sender, PoolKey calldata key, uint160 sqrtPriceX96, bytes calldata hookData)
        external
        returns (bytes4)
    {
        if (key.fee.isDynamicFee()) revert ForbiddenDynamicFee();
        (bool success, bytes memory returnData) = address(implementation).delegatecall(msg.data);
        if (!success) {
            assembly {
                revert(add(32, returnData), mload(returnData))
            }
        }
        return abi.decode(returnData, (bytes4));
    }

    function beforeSwap(address sender, PoolKey calldata key, IPoolManager.SwapParams calldata params, bytes calldata)
        external
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        try this._quoteSwapDelta(key, params) {}
        catch (bytes memory reason) {
            quote = abi.decode(reason, (BalanceDelta));
        }
        uint160 outputBefore = 0;
        (bool success, bytes memory returnData) = address(implementation).delegatecall(msg.data);
        if (!success) {
            assembly {
                revert(add(32, returnData), mload(returnData))
            }
        }
        return abi.decode(returnData, (bytes4, BeforeSwapDelta, uint24));
    }

    function _quoteSwapDelta(PoolKey memory key, IPoolManager.SwapParams memory params)
        external
        returns (bytes memory)
    {
        BalanceDelta swapDelta = manager.swap(key, params, ZERO_BYTES);
        bytes memory result = abi.encode(swapDelta);
        assembly {
            revert(add(0x20, result), mload(result))
        }
    }

    function afterSwap(address, PoolKey calldata, IPoolManager.SwapParams calldata, BalanceDelta delta, bytes calldata)
        external
        returns (bytes4, int128)
    {
        if (delta != quote) revert HookModifiedOutput();
        (bool success, bytes memory returnData) = address(implementation).delegatecall(msg.data);
        if (!success) {
            assembly {
                revert(add(32, returnData), mload(returnData))
            }
        }
        return abi.decode(returnData, (bytes4, int128));
    }

    function beforeAddLiquidity(
        address sender,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata params,
        bytes calldata hookData
    ) external returns (bytes4) {
        (bool success, bytes memory returnData) = address(this).delegatecall{gas: GAS_LIMIT}(
            abi.encodeWithSelector(this._callAndEnsurePrice.selector, msg.data)
        );
        if (!success) {
            assembly {
                revert(add(32, returnData), mload(returnData))
            }
        }
        return BaseHook.beforeAddLiquidity.selector;
    }
}
