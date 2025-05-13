//SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/console2.sol";
import {Test} from "forge-std/Test.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";

library CustomRevertDecoder {
    function decode(bytes memory err)
        internal
        pure
        returns (
            bytes4 wrappedErrorSelector,
            address revertingContract,
            bytes4 revertingFunctionSelector,
            bytes4 revertReasonSelector,
            bytes memory revertReason,
            bytes4 additionalContextSelector
        )
    {
        assembly {
            wrappedErrorSelector := mload(add(err, 0x20))
            revertingContract := mload(add(err, 0x24))
            revertingFunctionSelector := mload(add(err, 0x44))

            let offsetRevertReason := mload(add(err, 0x64))
            let offsetAdditionalContext := mload(add(err, 0x84))
            let sizeRevertReason := mload(add(err, add(offsetRevertReason, 0x24)))

            revertReasonSelector := mload(add(err, add(offsetRevertReason, 0x44)))
            additionalContextSelector := mload(add(err, add(offsetAdditionalContext, 0x44)))

            let ptr := mload(0x40)
            revertReason := ptr
            mstore(revertReason, sizeRevertReason)

            let w := not(0x1f)

            for { let s := and(add(sizeRevertReason, 0x20), w) } 1 {} {
                mstore(add(revertReason, s), mload(add(err, add(offsetRevertReason, add(0x24, s)))))
                s := add(s, w)
                if iszero(s) { break }
            }

            mstore(0x40, add(ptr, add(0x20, sizeRevertReason)))
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
