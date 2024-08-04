// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";

import {BaseTestHooks} from "@uniswap/v4-core/src/test/BaseTestHooks.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {IPositionManager} from "../../src/interfaces/IPositionManager.sol";

import "forge-std/console2.sol";

/// @notice This contract is NOT a production use contract. It is meant to be used in testing to verify the delta amounts against changes in a user's balance.
/// @dev a hook that can modify liquidity in beforeSwap
contract HookModifyLiquidities is BaseTestHooks {
    IPositionManager posm;
    IAllowanceTransfer permit2;

    function setAddresses(IPositionManager _posm, IAllowanceTransfer _permit2) external {
        posm = _posm;
        permit2 = _permit2;
    }

    function beforeSwap(
        address, /* sender **/
        PoolKey calldata key, /* key **/
        IPoolManager.SwapParams calldata, /* params **/
        bytes calldata hookData
    ) external override returns (bytes4, BeforeSwapDelta, uint24) {
        approvePosmCurrency(key.currency0);
        approvePosmCurrency(key.currency1);

        (bytes memory actions, bytes[] memory params) = abi.decode(hookData, (bytes, bytes[]));
        console2.log("WAAAA");
        posm.modifyLiquidities(actions, params);
        console2.log(address(posm));
        return (BaseTestHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    function approvePosmCurrency(Currency currency) internal {
        // Because POSM uses permit2, we must execute 2 permits/approvals.
        // 1. First, the caller must approve permit2 on the token.
        IERC20(Currency.unwrap(currency)).approve(address(permit2), type(uint256).max);
        // 2. Then, the caller must approve POSM as a spender of permit2. TODO: This could also be a signature.
        permit2.approve(Currency.unwrap(currency), address(posm), type(uint160).max, type(uint48).max);
    }
}
