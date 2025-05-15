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

import {CustomRevertDecoder} from "../../src/utils/CustomRevertDecoder.sol";

contract CustomRevertDecoderTest is Test {
    function setUp() public {}

    function test_fuzz_decode_customRevert(
        bytes4 wrappedErrorSelector,
        address revertingContract,
        bytes4 revertingFunctionSelector,
        bytes4 revertReasonSelector,
        bytes memory reasonData,
        bytes4 additionalContextSelector
    ) public pure {
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
            bytes4 _decodedRevertReasonSelector,
            bytes memory _decodedReason,
            bytes4 _decodedAdditionalContextSelector
        ) = CustomRevertDecoder.decode(data);

        assertEq(_decodedWrapSelector, wrappedErrorSelector);
        assertEq(_decodedRevertingContract, revertingContract);
        assertEq(_decodedRevertingFunctionSelector, revertingFunctionSelector);
        assertEq(_decodedRevertReasonSelector, revertReasonSelector);
        assertEq(_decodedReason, abi.encodeWithSelector(revertReasonSelector, reasonData));
        assertEq(_decodedAdditionalContextSelector, additionalContextSelector);
    }

    function test_decode_empty() public pure {
        bytes4 wrappedErrorSelector = CustomRevert.WrappedError.selector;
        address revertingContract = address(0x1111);
        bytes4 revertingFunctionSelector = bytes4(0);
        bytes4 revertReasonSelector = bytes4(0);
        bytes4 additionalContextSelector = CurrencyLibrary.NativeTransferFailed.selector;

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
            bytes4 _decodedRevertReasonSelector,
            bytes memory _decodedReason,
            bytes4 _decodedAdditionalContextSelector
        ) = CustomRevertDecoder.decode(data);

        // assert original values against decoded values
        assertEq(_decodedWrapSelector, wrappedErrorSelector);
        assertEq(_decodedRevertingContract, revertingContract);
        assertEq(_decodedRevertingFunctionSelector, revertingFunctionSelector);
        assertEq(_decodedRevertReasonSelector, revertReasonSelector);
        assertEq(_decodedReason, abi.encodeWithSelector(revertReasonSelector));
        assertEq(_decodedAdditionalContextSelector, additionalContextSelector);
    }

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
            bytes4 _decodedRevertReasonSelector,
            bytes memory _decodedRevertReason,
            bytes4 _decodedAdditionalContextSelector
        ) = CustomRevertDecoder.decode(data);

        // assert original values against decoded values
        assertEq(_decodedWrapSelector, wrappedErrorSelector);
        assertEq(_decodedRevertingContract, revertingContract);
        assertEq(_decodedRevertingFunctionSelector, revertingFunctionSelector);
        assertEq(_decodedRevertReasonSelector, revertReasonSelector);
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
            bytes4 _decodedRevertReasonSelector,
            bytes memory _decodedReason,
            bytes4 _decodedAdditionalContextSelector
        ) = CustomRevertDecoder.decode(data);

        // assert original values against decoded values
        assertEq(_decodedWrapSelector, wrappedErrorSelector);
        assertEq(_decodedRevertingContract, revertingContract);
        assertEq(_decodedRevertingFunctionSelector, revertingFunctionSelector);
        assertEq(_decodedRevertReasonSelector, bytes4(0));
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
            bytes4 _decodedRevertReasonSelector,
            bytes memory _decodedReason,
            bytes4 _decodedAdditionalContextSelector
        ) = CustomRevertDecoder.decode(data);

        // assert original values against decoded values
        assertEq(_decodedWrapSelector, wrappedErrorSelector);
        assertEq(_decodedRevertingContract, revertingContract);
        assertEq(_decodedRevertingFunctionSelector, revertingFunctionSelector);
        assertEq(_decodedRevertReasonSelector, revertReasonSelector);
        assertEq(_decodedReason, abi.encodeWithSelector(revertReasonSelector));
        assertEq(_decodedAdditionalContextSelector, additionalContextSelector);
    }
}
