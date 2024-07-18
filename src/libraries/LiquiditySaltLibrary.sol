// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";

/// @notice Library used to interact with PoolManager.sol to settle any open deltas.
/// To settle a positive delta (a credit to the user), a user may take or mint.
/// To settle a negative delta (a debt on the user), a user make transfer or burn to pay off a debt.
/// @dev Note that sync() is called before any erc-20 transfer in `settle`.
library LiquiditySaltLibrary {
    /// @notice Calculates the salt parameters for IPoolManager.ModifyLiquidityParams
    /// If the hook uses after*LiquidityReturnDelta, the salt is the address of the sender
    /// otherwise, use 0 for warm-storage gas savings
    function getLiquiditySalt(IHooks hooks, address sender) internal pure returns (bytes32 salt) {
        salt = Hooks.hasPermission(hooks, Hooks.AFTER_ADD_LIQUIDITY_RETURNS_DELTA_FLAG)
            || Hooks.hasPermission(hooks, Hooks.AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA_FLAG)
            ? bytes32(uint256(uint160(sender)))
            : bytes32(0);
    }
}
