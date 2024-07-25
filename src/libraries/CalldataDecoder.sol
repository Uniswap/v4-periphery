// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.0;

/// @title Library for abi decoding in calldata
library CalldataDecoder {
    error SliceOutOfBounds();

    /// @notice equivalent to SliceOutOfBounds.selector
    bytes4 constant SLICE_ERROR_SELECTOR = 0x3b99b53d;

    /// @notice Performs the equivalent of `abi.decode(data, (uint256[], bytes[]))` in calldata
    /// @param _bytes The input bytes string to extract input arrays from
    /// @return actions The uint256 calldata array of actions
    /// @return params The bytes calldata array of parameters
    function decodeActionsRouterParams(bytes calldata _bytes)
        internal
        pure
        returns (uint256[] calldata actions, bytes[] calldata params)
    {
        assembly ("memory-safe") {
            // The offset of the 0th element is 0, which stores the offset of the length pointer of actions array.
            // The offset of the 1st element is 32, which stores the offset of the length pointer of params array.
            let actionsPtr := add(_bytes.offset, calldataload(_bytes.offset))
            let paramsPtr := add(_bytes.offset, calldataload(add(_bytes.offset, 0x20)))

            // The length is stored as the first element
            actions.length := calldataload(actionsPtr)
            params.length := calldataload(paramsPtr)

            // The actual data is stored in the slot after the length
            actions.offset := add(actionsPtr, 0x20)
            params.offset := add(paramsPtr, 0x20)

            // Calculate how far `params` is into the provided bytes
            let relativeOffset := sub(params.offset, _bytes.offset)
            // Check that that isnt longer than the bytes themselves, or revert
            if lt(_bytes.length, add(params.length, relativeOffset)) {
                mstore(0, SLICE_ERROR_SELECTOR)
                revert(0, 0x04)
            }
        }
    }
}
