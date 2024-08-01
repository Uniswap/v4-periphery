// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.19;

import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";

import {IMulticall} from "../interfaces/IMulticall.sol";

import "forge-std/console2.sol";

/// @title Multicall
/// @notice Enables calling multiple methods in a single call to the contract
abstract contract Multicall is IMulticall {
    using CustomRevert for bytes4;

    /// @inheritdoc IMulticall
    function multicall(bytes[] calldata data) public payable override returns (bytes[] memory results) {
        results = new bytes[](data.length);
        for (uint256 i = 0; i < data.length; i++) {
            (bool success, bytes memory result) = address(this).delegatecall(data[i]);

            if (!success) {
                // bubble up the revert reason
                assembly {
                    revert(add(result, 0x20), mload(result))
                }
            }

            results[i] = result;
        }
    }
}
