// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import {ISwapAndAdd} from "../../../src/interfaces/ISwapAndAdd.sol";
import {BttBase} from "./BttBase.sol";

contract ValidateRecipientTest is BttBase {
    function test_WhenRecipientIsZero_Reverts() public {
        // it reverts with {InvalidRecipient}
        vm.expectRevert(abi.encodeWithSelector(ISwapAndAdd.InvalidRecipient.selector, address(0)));
        zap.exposedValidateRecipient(address(0));
    }

    function test_WhenRecipientIsZap_Reverts() public {
        // it reverts with {InvalidRecipient}
        vm.expectRevert(abi.encodeWithSelector(ISwapAndAdd.InvalidRecipient.selector, address(zap)));
        zap.exposedValidateRecipient(address(zap));
    }

    function test_WhenRecipientIsAnyOtherAddress_Succeeds() public {
        // it succeeds
        zap.exposedValidateRecipient(address(this));
        zap.exposedValidateRecipient(makeAddr("alice"));
    }
}
