// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ISubscriber} from "../../src/interfaces/ISubscriber.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PositionInfo} from "../../src/libraries/PositionInfoLibrary.sol";

/// @notice Subscriber that leaves an UNSETTLED PoolManager delta during `notifyUnsubscribe`.
///         On the callback it mints 1 wei of the native-ETH ERC-6909 claim to itself, which charges
///         the subscriber a -1 delta, then returns normally. Native ETH (currency id 0) needs no
///         balance, approval, or allowlist clearance.
/// @dev The callback returns cleanly, so the gas-capped try/catch in `_unsubscribe` has nothing to
///      catch. If the callback runs inside an open PoolManager unlock, the enclosing `unlock` reverts
///      with `CurrencyNotSettled` after the callback returns and bricks the force-exit. When the
///      unsubscribe runs with the manager locked, the `mint` instead reverts with `ManagerLocked`
///      inside the callback and is absorbed by the try/catch.
contract MockFlashAttackSubscriber is ISubscriber {
    IPoolManager public immutable manager;
    uint256 public notifyUnsubscribeCount;

    constructor(IPoolManager _manager) {
        manager = _manager;
    }

    function notifySubscribe(uint256, bytes memory) external {}

    function notifyUnsubscribe(uint256) external {
        manager.mint(address(this), 0, 1);
        notifyUnsubscribeCount++;
    }

    function notifyModifyLiquidity(uint256, int256, BalanceDelta) external {}

    function notifyBurn(uint256, address, PositionInfo, uint256, BalanceDelta) external {}
}
