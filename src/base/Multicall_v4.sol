// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IMulticall_v4} from "../interfaces/IMulticall_v4.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";

/// @title Multicall_v4
/// @notice Enables calling multiple methods in a single call to the contract
abstract contract Multicall_v4 is IMulticall_v4 {
    using CustomRevert for bytes4;

    /// @notice Maximum number of calls allowed in a single multicall to prevent gas bombs
    uint256 public constant MAX_MULTICALL_LENGTH = 50;
    
    /// @notice Minimum gas required per call to prevent gas griefing
    uint256 public constant MIN_GAS_PER_CALL = 50000;
    
    /// @notice Thrown when multicall array exceeds maximum allowed length
    error MulticallTooManyOps(uint256 length, uint256 maxLength);
    
    /// @notice Thrown when insufficient gas for safe multicall execution
    error MulticallInsufficientGas(uint256 available, uint256 required);

    /// @inheritdoc IMulticall_v4
    function multicall(bytes[] calldata data) external payable returns (bytes[] memory results) {
        // Critical protection: Limit array length to prevent gas bomb attacks
        if (data.length > MAX_MULTICALL_LENGTH) {
            MulticallTooManyOps.selector.revertWith(data.length, MAX_MULTICALL_LENGTH);
        }
        
        // Additional protection: Ensure sufficient gas for safe execution
        uint256 requiredGas = data.length * MIN_GAS_PER_CALL;
        if (gasleft() < requiredGas) {
            MulticallInsufficientGas.selector.revertWith(gasleft(), requiredGas);
        }
        
        results = new bytes[](data.length);
        for (uint256 i = 0; i < data.length; i++) {
            // Gas monitoring: Ensure sufficient gas remains for each call
            if (gasleft() < MIN_GAS_PER_CALL) {
                MulticallInsufficientGas.selector.revertWith(gasleft(), MIN_GAS_PER_CALL);
            }
            
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
