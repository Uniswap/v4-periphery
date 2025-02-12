// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {BaseHook} from "../../src/utils/BaseHook.sol";

contract MockBlankHook is BaseHook {
    uint256 public num;
    Hooks.Permissions permissions;

    constructor(IPoolManager _poolManager, uint256 _num, uint16 _flags) BaseHook(_poolManager) {
        num = _num;

        permissions = Hooks.Permissions({
            beforeInitialize: (_flags & Hooks.BEFORE_INITIALIZE_FLAG) != 0,
            afterInitialize: (_flags & Hooks.AFTER_INITIALIZE_FLAG) != 0,
            beforeAddLiquidity: (_flags & Hooks.BEFORE_ADD_LIQUIDITY_FLAG) != 0,
            afterAddLiquidity: (_flags & Hooks.AFTER_ADD_LIQUIDITY_FLAG) != 0,
            beforeRemoveLiquidity: (_flags & Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG) != 0,
            afterRemoveLiquidity: (_flags & Hooks.AFTER_REMOVE_LIQUIDITY_FLAG) != 0,
            beforeSwap: (_flags & Hooks.BEFORE_SWAP_FLAG) != 0,
            afterSwap: (_flags & Hooks.AFTER_SWAP_FLAG) != 0,
            beforeDonate: (_flags & Hooks.BEFORE_DONATE_FLAG) != 0,
            afterDonate: (_flags & Hooks.AFTER_DONATE_FLAG) != 0,
            beforeSwapReturnDelta: (_flags & Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG) != 0,
            afterSwapReturnDelta: (_flags & Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG) != 0,
            afterAddLiquidityReturnDelta: (_flags & Hooks.AFTER_ADD_LIQUIDITY_RETURNS_DELTA_FLAG) != 0,
            afterRemoveLiquidityReturnDelta: (_flags & Hooks.AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA_FLAG) != 0
        });
    }

    /// @dev Because of C3 Linearization, BaseHook's constructor is executed first
    /// do not verify the address until the flags have been set by MockBlankHook's constructor
    function validateHookAddress(BaseHook _this) internal pure override {}

    /// @dev cannot override getHookPermissions() since its designated pure, and we cant make it view
    /// therefore lets in-line the permissions here
    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {}

    function forceValidateAddress() external view {
        Hooks.validateHookPermissions(IHooks(address(this)), permissions);
    }
}
