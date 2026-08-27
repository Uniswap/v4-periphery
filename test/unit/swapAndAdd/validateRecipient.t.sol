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

    /// @dev Wiring pin: a new entrypoint that forgets the call must fail here.
    function test_WhenRecipientIsInvalid_EveryEntrypointRejectsIt() public {
        // it reverts with {InvalidRecipient} from add, increase, rebalance, and compound
        address[2] memory bad = [address(0), address(zap)];
        uint256 tokenId = _mintPositionViaAdd(0, 10e18);

        for (uint256 i = 0; i < bad.length; i++) {
            bytes memory expected = abi.encodeWithSelector(ISwapAndAdd.InvalidRecipient.selector, bad[i]);

            ISwapAndAdd.AddParams memory addParams = _addParams(0, 10e18);
            addParams.recipient = bad[i];
            vm.expectRevert(expected);
            zap.add(addParams);

            ISwapAndAdd.IncreaseParams memory increaseParams = _increaseParams(tokenId, 0, 10e18);
            increaseParams.recipient = bad[i];
            vm.expectRevert(expected);
            zap.increase(increaseParams);

            ISwapAndAdd.RebalanceParams memory rebalanceParams = _rebalanceParams(tokenId, 0, 0);
            rebalanceParams.recipient = bad[i];
            vm.expectRevert(expected);
            zap.rebalance(rebalanceParams);

            ISwapAndAdd.CompoundParams memory compoundParams = _compoundParams(tokenId, 0);
            compoundParams.recipient = bad[i];
            vm.expectRevert(expected);
            zap.compound(compoundParams);
        }
    }
}
