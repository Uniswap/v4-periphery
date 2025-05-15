//SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/console2.sol";
import {Test} from "forge-std/Test.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";

library CustomRevertDecoder {
    function decode(bytes memory err)
        internal
        pure
        returns (
            bytes4 wrappedErrorSelector,
            address revertingContract,
            bytes4 revertingFunctionSelector,
            bytes4 revertrevertReasonSelector,
            bytes memory revertReason,
            bytes4 additionalContextSelector
        )
    {
        console2.logBytes(err);
        bytes32 x;
        bytes32 y;
        assembly {
            wrappedErrorSelector := mload(add(err, 0x20))
            revertingContract := mload(add(err, 0x24))
            revertingFunctionSelector := mload(add(err, 0x44))

            let offsetRevertReason := mload(add(err, 0x64))
            let offsetAdditionalContext := mload(add(err, 0x84))
            let sizeRevertReason := mload(add(err, add(offsetRevertReason, 0x24)))

            revertrevertReasonSelector := mload(add(err, add(offsetRevertReason, 0x44)))
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
        console2.logBytes32(y);
        console2.logBytes32(x);
    }
}

contract CustomRevertDecoderTest is Test {
    function setUp() public {}

    // function test_decode_empty() public pure {
    //     bytes4 wrappedErrorSelector = CustomRevert.WrappedError.selector;
    //     address revertingContract = address(0x1111);
    //     bytes4 revertingFunctionSelector = bytes4(0);
    //     bytes4 revertReasonSelector = bytes4(0);
    //     // bytes memory reason = abi.encode(uint24(10000));
    //     bytes4 additionalContextSelector = CurrencyLibrary.NativeTransferFailed.selector;

    //     bytes memory data = abi.encodeWithSelector(
    //         wrappedErrorSelector,
    //         revertingContract,
    //         revertingFunctionSelector,
    //         abi.encodeWithSelector(revertReasonSelector),
    //         abi.encodeWithSelector(additionalContextSelector)
    //     );

    //     (
    //         bytes4 _decodedWrapSelector,
    //         address _decodedRevertingContract,
    //         bytes4 _decodedRevertingFunctionSelector,
    //         bytes4 _decodedrevertReasonSelector,
    //         bytes memory _decodedReason,
    //         bytes4 _decodedAdditionalContextSelector
    //     ) = CustomRevertDecoder.decode(data);

    //     // assert original values against decoded values
    //     assertEq(_decodedWrapSelector, wrappedErrorSelector);
    //     assertEq(_decodedRevertingContract, revertingContract);
    //     assertEq(_decodedRevertingFunctionSelector, revertingFunctionSelector);
    //     assertEq(_decodedrevertReasonSelector, revertReasonSelector);
    //     assertEq(_decodedReason, "");
    //     assertEq(_decodedAdditionalContextSelector, additionalContextSelector);
    // }

    function test_decode_singleParameter() public pure {
        bytes4 wrappedErrorSelector = CustomRevert.WrappedError.selector;
        address revertingContract = address(0x1111);
        bytes4 revertingFunctionSelector = IHooks.afterInitialize.selector;
        bytes4 revertReasonSelector = LPFeeLibrary.LPFeeTooLarge.selector;
        uint24 reasonData = uint24(10000);
        bytes4 additionalContextSelector = Hooks.HookCallFailed.selector;

        bytes memory data = abi.encodeWithSelector(
            wrappedErrorSelector,
            revertingContract,
            revertingFunctionSelector,
            abi.encodeWithSelector(revertReasonSelector, reasonData),
            abi.encodeWithSelector(additionalContextSelector)
        );

        (
            bytes4 _decodedWrapSelector,
            address _decodedRevertingContract,
            bytes4 _decodedRevertingFunctionSelector,
            bytes4 _decodedrevertReasonSelector,
            bytes memory _decodedRevertReason,
            bytes4 _decodedAdditionalContextSelector
        ) = CustomRevertDecoder.decode(data);

        // assert original values against decoded values
        assertEq(_decodedWrapSelector, wrappedErrorSelector);
        assertEq(_decodedRevertingContract, revertingContract);
        assertEq(_decodedRevertingFunctionSelector, revertingFunctionSelector);
        assertEq(_decodedrevertReasonSelector, revertReasonSelector);
        assertEq(_decodedRevertReason, abi.encodeWithSelector(revertReasonSelector, reasonData));
        assertEq(_decodedAdditionalContextSelector, additionalContextSelector);
    }

    function test_decode_norevertReasonSelector() public pure {
        bytes4 wrappedErrorSelector = CustomRevert.WrappedError.selector;
        address revertingContract = address(0x1111);
        bytes4 revertingFunctionSelector = IHooks.afterInitialize.selector;
        bytes32 reason = bytes32(0);
        bytes4 additionalContextSelector = CurrencyLibrary.ERC20TransferFailed.selector;

        bytes memory data = abi.encodeWithSelector(
            wrappedErrorSelector,
            revertingContract,
            revertingFunctionSelector,
            abi.encode(reason),
            abi.encodeWithSelector(additionalContextSelector)
        );

        (
            bytes4 _decodedWrapSelector,
            address _decodedRevertingContract,
            bytes4 _decodedRevertingFunctionSelector,
            bytes4 _decodedrevertReasonSelector,
            bytes memory _decodedReason,
            bytes4 _decodedAdditionalContextSelector
        ) = CustomRevertDecoder.decode(data);

        // assert original values against decoded values
        assertEq(_decodedWrapSelector, wrappedErrorSelector);
        assertEq(_decodedRevertingContract, revertingContract);
        assertEq(_decodedRevertingFunctionSelector, revertingFunctionSelector);
        assertEq(_decodedrevertReasonSelector, bytes4(0));
        assertEq(_decodedReason, abi.encode(reason));
        assertEq(_decodedAdditionalContextSelector, additionalContextSelector);
    }

    function test_decode_noReason() public pure {
        bytes4 wrappedErrorSelector = CustomRevert.WrappedError.selector;
        address revertingContract = address(0x1111);
        bytes4 revertingFunctionSelector = IHooks.afterInitialize.selector;
        bytes4 revertReasonSelector = IPoolManager.UnauthorizedDynamicLPFeeUpdate.selector;
        bytes4 additionalContextSelector = Hooks.HookCallFailed.selector;

        bytes memory data = abi.encodeWithSelector(
            wrappedErrorSelector,
            revertingContract,
            revertingFunctionSelector,
            abi.encodeWithSelector(revertReasonSelector),
            abi.encodeWithSelector(additionalContextSelector)
        );

        (
            bytes4 _decodedWrapSelector,
            address _decodedRevertingContract,
            bytes4 _decodedRevertingFunctionSelector,
            bytes4 _decodedrevertReasonSelector,
            bytes memory _decodedReason,
            bytes4 _decodedAdditionalContextSelector
        ) = CustomRevertDecoder.decode(data);

        // assert original values against decoded values
        assertEq(_decodedWrapSelector, wrappedErrorSelector);
        assertEq(_decodedRevertingContract, revertingContract);
        assertEq(_decodedRevertingFunctionSelector, revertingFunctionSelector);
        assertEq(_decodedrevertReasonSelector, revertReasonSelector);
        assertEq(_decodedReason, abi.encodeWithSelector(revertReasonSelector));
        assertEq(_decodedAdditionalContextSelector, additionalContextSelector);
    }
}
