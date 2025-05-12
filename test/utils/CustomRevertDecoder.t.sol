//SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/console2.sol";
import {Test} from "forge-std/Test.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";

library CustomRevertDecoder {
    function decode(bytes memory data)
        internal
        pure
        returns (
            bytes4 wrappedErrorSelector,
            address originAddress,
            bytes4 originFunction,
            bytes4 reasonSelector,
            bytes memory reason,
            bytes4 detailsSelector
        )
    {
        assembly {
            wrappedErrorSelector := mload(add(data, 32))
            originAddress := mload(add(data, 36))
            originFunction := mload(add(data, 68)) // 36 + 32

            let reasonSelectorOffset := mload(add(data, 100)) // 68 + 32
            let detailsSelectorOffset := mload(add(data, 132)) // 100 + 32
            let reasonOffset := mload(add(data, 164)) // 132 + 32

            reasonSelector := mload(add(data, add(68, reasonSelectorOffset))) // 68 + offset
            detailsSelector := mload(add(data, add(68, detailsSelectorOffset))) // 68 + offset + offset
            reason := mload(add(data, add(36, add(reasonSelectorOffset, reasonOffset)))) // 68 + offset + offset + offset
        }
    }
}

contract CustomRevertDecoderTest is Test {
    function setUp() public {}

    function test_decode() public pure {
        bytes4 wrappedErrorSelector = CustomRevert.WrappedError.selector;
        address originAddress = address(0x1111);
        bytes4 originFunction = IHooks.afterInitialize.selector;
        bytes4 reasonSelector = LPFeeLibrary.LPFeeTooLarge.selector;
        // bytes memory reason = abi.encode(uint24(10000));
        bytes4 detailsSelector = Hooks.HookCallFailed.selector;

        bytes memory data = abi.encodeWithSelector(
            wrappedErrorSelector,
            originAddress,
            originFunction,
            abi.encodeWithSelector(reasonSelector, uint24(10000)),
            abi.encodeWithSelector(detailsSelector)
        );

        (
            bytes4 _decodedWrapSelector,
            address _decodedOriginAddress,
            bytes4 _decodedOriginFunction,
            bytes4 _decodedReasonSelector,
            ,
            bytes4 _decodedDetailsSelector
        ) = CustomRevertDecoder.decode(data);

        // assert original values against decoded values
        assertEq(_decodedWrapSelector, wrappedErrorSelector);
        assertEq(_decodedOriginAddress, originAddress);
        assertEq(_decodedOriginFunction, originFunction);
        assertEq(_decodedReasonSelector, reasonSelector);
        assertEq(_decodedDetailsSelector, detailsSelector);
    }
}
