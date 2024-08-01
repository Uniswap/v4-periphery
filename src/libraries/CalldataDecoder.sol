// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.0;

import {PositionConfig} from "./PositionConfig.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

/// @title Library for abi decoding in calldata
library CalldataDecoder {
    using CalldataDecoder for bytes;

    error SliceOutOfBounds();

    /// @notice equivalent to SliceOutOfBounds.selector
    bytes4 constant SLICE_ERROR_SELECTOR = 0x3b99b53d;

    /// @dev equivalent to: abi.decode(params, (uint256[], bytes[])) in calldata
    function decodeActionsRouterParams(bytes calldata _bytes)
        internal
        pure
        returns (bytes calldata actions, bytes[] calldata params)
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

    /// @dev equivalent to: abi.decode(params, (uint256, PositionConfig, uint256, bytes)) in calldata
    function decodeModifyLiquidityParams(bytes calldata params)
        internal
        pure
        returns (uint256 tokenId, PositionConfig calldata config, uint256 liquidity, bytes calldata hookData)
    {
        assembly ("memory-safe") {
            tokenId := calldataload(params.offset)
            config := add(params.offset, 0x20)
            liquidity := calldataload(add(params.offset, 0x100))
        }
        hookData = params.toBytes(9);
    }

    /// @dev equivalent to: abi.decode(params, (PositionConfig, uint256, address, bytes)) in calldata
    function decodeMintParams(bytes calldata params)
        internal
        pure
        returns (PositionConfig calldata config, uint256 liquidity, address owner, bytes calldata hookData)
    {
        assembly ("memory-safe") {
            config := params.offset
            liquidity := calldataload(add(params.offset, 0xe0))
            owner := calldataload(add(params.offset, 0x100))
        }
        hookData = params.toBytes(9);
    }

    /// @dev equivalent to: abi.decode(params, (uint256, PositionConfig, bytes)) in calldata
    function decodeBurnParams(bytes calldata params)
        internal
        pure
        returns (uint256 tokenId, PositionConfig calldata config, bytes calldata hookData)
    {
        assembly ("memory-safe") {
            tokenId := calldataload(params.offset)
            config := add(params.offset, 0x20)
        }
        hookData = params.toBytes(8);
    }

    /// @dev equivalent to: abi.decode(params, (Currency)) in calldata
    function decodeCurrency(bytes calldata params) internal pure returns (Currency currency) {
        assembly ("memory-safe") {
            currency := calldataload(params.offset)
        }
    }

    /// @dev equivalent to: abi.decode(params, (Currency, address)) in calldata
    function decodeCurrencyAndAddress(bytes calldata params)
        internal
        pure
        returns (Currency currency, address _address)
    {
        assembly ("memory-safe") {
            currency := calldataload(params.offset)
            _address := calldataload(add(params.offset, 0x20))
        }
    }

    /// @notice Decode the `_arg`-th element in `_bytes` as a dynamic array
    /// @dev The decoding of `length` and `offset` is universal,
    /// whereas the type declaration of `res` instructs the compiler how to read it.
    /// @param _bytes The input bytes string to slice
    /// @param _arg The index of the argument to extract
    /// @return length Length of the array
    /// @return offset Pointer to the data part of the array
    function toLengthOffset(bytes calldata _bytes, uint256 _arg)
        internal
        pure
        returns (uint256 length, uint256 offset)
    {
        uint256 relativeOffset;
        assembly ("memory-safe") {
            // The offset of the `_arg`-th element is `32 * arg`, which stores the offset of the length pointer.
            // shl(5, x) is equivalent to mul(32, x)
            let lengthPtr := add(_bytes.offset, calldataload(add(_bytes.offset, shl(5, _arg))))
            length := calldataload(lengthPtr)
            offset := add(lengthPtr, 0x20)
            relativeOffset := sub(offset, _bytes.offset)
        }
        if (_bytes.length < length + relativeOffset) revert SliceOutOfBounds();
    }

    /// @notice Decode the `_arg`-th element in `_bytes` as `bytes`
    /// @param _bytes The input bytes string to extract a bytes string from
    /// @param _arg The index of the argument to extract
    function toBytes(bytes calldata _bytes, uint256 _arg) internal pure returns (bytes calldata res) {
        (uint256 length, uint256 offset) = toLengthOffset(_bytes, _arg);
        assembly ("memory-safe") {
            res.length := length
            res.offset := offset
        }
    }
}
