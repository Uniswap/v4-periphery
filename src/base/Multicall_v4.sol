// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IMulticall_v4} from "../interfaces/IMulticall_v4.sol";

/// @title Multicall_v4
/// @notice Enables calling multiple methods in a single call to the contract
abstract contract Multicall_v4 is IMulticall_v4 {
    /// @inheritdoc IMulticall_v4
    function multicall(bytes[] calldata data) external payable returns (bytes[] memory results) {
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
