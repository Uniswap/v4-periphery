// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {IMsgSender} from "../../../../src/interfaces/IMsgSender.sol";

/// @notice A wrapper absent from an adapter's `allowedWrappers` list.
/// @dev Reports a `msgSender` that holds the required flag, so a revert is attributable to the wrapper
///      check rather than the permission check. A wrapper without `msgSender()` is rejected earlier, on
///      the hook's staticcall, which proves nothing.
contract MockUnapprovedWrapper is PoolSwapTest, IMsgSender {
    address private immutable SENDER;

    constructor(IPoolManager manager_, address sender_) PoolSwapTest(manager_) {
        SENDER = sender_;
    }

    /// @inheritdoc IMsgSender
    function msgSender() external view returns (address) {
        return SENDER;
    }
}
