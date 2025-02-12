// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {HookMiner} from "../../src/libraries/HookMiner.sol";
import {BaseHook} from "../../src/utils/BaseHook.sol";

contract MockBlankHook is BaseHook {
    using Hooks for IHooks;

    uint256 public num;

    bool usesBeforeInitialize;
    bool usesAfterInitialize;
    bool usesBeforeAddLiquidity;
    bool usesAfterAddLiquidity;
    bool usesBeforeRemoveLiquidity;
    bool usesAfterRemoveLiquidity;
    bool usesBeforeSwap;
    bool usesAfterSwap;
    bool usesBeforeDonate;
    bool usesAfterDonate;
    bool usesBeforeSwapReturnDelta;
    bool usesAfterSwapReturnDelta;
    bool usesAfterAddLiquidityReturnDelta;
    bool usesAfterRemoveLiquidityReturnDelta;

    constructor(IPoolManager _poolManager, uint256 _num, uint16 _flags) BaseHook(_poolManager) {
        num = _num;
        usesBeforeInitialize = (_flags & Hooks.BEFORE_INITIALIZE_FLAG) != 0;
        usesAfterInitialize = (_flags & Hooks.AFTER_INITIALIZE_FLAG) != 0;
        usesBeforeAddLiquidity = (_flags & Hooks.BEFORE_ADD_LIQUIDITY_FLAG) != 0;
        usesAfterAddLiquidity = (_flags & Hooks.AFTER_ADD_LIQUIDITY_FLAG) != 0;
        usesBeforeRemoveLiquidity = (_flags & Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG) != 0;
        usesAfterRemoveLiquidity = (_flags & Hooks.AFTER_REMOVE_LIQUIDITY_FLAG) != 0;
        usesBeforeSwap = (_flags & Hooks.BEFORE_SWAP_FLAG) != 0;
        usesAfterSwap = (_flags & Hooks.AFTER_SWAP_FLAG) != 0;
        usesBeforeDonate = (_flags & Hooks.BEFORE_DONATE_FLAG) != 0;
        usesAfterDonate = (_flags & Hooks.AFTER_DONATE_FLAG) != 0;
        usesBeforeSwapReturnDelta = (_flags & Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG) != 0;
        usesAfterSwapReturnDelta = (_flags & Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG) != 0;
        usesAfterAddLiquidityReturnDelta = (_flags & Hooks.AFTER_ADD_LIQUIDITY_RETURNS_DELTA_FLAG) != 0;
        usesAfterRemoveLiquidityReturnDelta = (_flags & Hooks.AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA_FLAG) != 0;
    }

    /// @dev Because of C3 Linearization, BaseHook's constructor is executed first
    /// do not verify the address until the flags have been set by MockBlankHook's constructor
    function validateHookAddress(BaseHook _this) internal pure override {}

    /// @dev cannot override getHookPermissions() since its designated pure, and we cant make it view
    /// therefore lets in-line the permissions here
    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {}

    function forceValidateAddress() external {
        Hooks.validateHookPermissions(
            IHooks(address(this)),
            Hooks.Permissions({
                beforeInitialize: usesBeforeInitialize,
                afterInitialize: usesAfterInitialize,
                beforeAddLiquidity: usesBeforeAddLiquidity,
                afterAddLiquidity: usesAfterAddLiquidity,
                beforeRemoveLiquidity: usesBeforeRemoveLiquidity,
                afterRemoveLiquidity: usesAfterRemoveLiquidity,
                beforeSwap: usesBeforeSwap,
                afterSwap: usesAfterSwap,
                beforeDonate: usesBeforeDonate,
                afterDonate: usesAfterDonate,
                beforeSwapReturnDelta: usesBeforeSwapReturnDelta,
                afterSwapReturnDelta: usesAfterSwapReturnDelta,
                afterAddLiquidityReturnDelta: usesAfterAddLiquidityReturnDelta,
                afterRemoveLiquidityReturnDelta: usesAfterRemoveLiquidityReturnDelta
            })
        );
    }
}
