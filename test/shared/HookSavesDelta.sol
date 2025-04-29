// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";

import {BaseTestHooks} from "@uniswap/v4-core/src/test/BaseTestHooks.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

/// @notice This contract is NOT a production use contract. It is meant to be used in testing to verify the delta amounts against changes in a user's balance.
contract HookSavesDelta is BaseTestHooks {
    BalanceDelta[] public deltas;

    function afterAddLiquidity(
        address, /* sender **/
        PoolKey calldata, /* key **/
        ModifyLiquidityParams calldata, /* params **/
        BalanceDelta delta,
        BalanceDelta, /* feesAccrued **/
        bytes calldata /* hookData **/
    ) external override returns (bytes4, BalanceDelta) {
        _storeDelta(delta);
        return (this.afterAddLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }

    function afterRemoveLiquidity(
        address, /* sender **/
        PoolKey calldata, /* key **/
        ModifyLiquidityParams calldata, /* params **/
        BalanceDelta delta,
        BalanceDelta, /* feesAccrued */
        bytes calldata /* hookData **/
    ) external override returns (bytes4, BalanceDelta) {
        _storeDelta(delta);
        return (this.afterRemoveLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }

    function _storeDelta(BalanceDelta delta) internal {
        deltas.push(delta);
    }

    function numberDeltasReturned() external view returns (uint256) {
        return deltas.length;
    }

    function clearDeltas() external {
        delete deltas;
    }
}
