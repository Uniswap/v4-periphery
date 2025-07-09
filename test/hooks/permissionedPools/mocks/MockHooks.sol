// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IWrappedPermissionedTokenFactory} from
    "../../../../src/hooks/permissionedPools/interfaces/IWrappedPermissionedTokenFactory.sol";
import {PermissionedHooks} from "../../../../src/hooks/permissionedPools/PermissionedHooks.sol";

contract MockHooks is PermissionedHooks {
    constructor(IPoolManager manager, IWrappedPermissionedTokenFactory wrappedTokenFactory)
        PermissionedHooks(manager, wrappedTokenFactory)
    {}
}

/// @notice This contract is used in the testing of security for the permissioned pool manager
contract MockInsecureHooks {
    function beforeAddLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        return IHooks.beforeAddLiquidity.selector;
    }

    function beforeSwap(address, PoolKey calldata, SwapParams calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        return IHooks.beforeSwap.selector;
    }

    receive() external payable {}
}
