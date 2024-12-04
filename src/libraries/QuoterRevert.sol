// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {ParseBytes} from "@uniswap/v4-core/src/libraries/ParseBytes.sol";

library QuoterRevert {
    using QuoterRevert for bytes;
    using ParseBytes for bytes;

    /// @notice error thrown when invalid revert bytes are thrown by the quote
    error UnexpectedRevertBytes(bytes revertData);

    /// @notice error thrown containing the quote as the data, to be caught and parsed later
    error QuoteSwap(uint256 amount);

    /// @notice reverts, where the revert data is the provided bytes
    /// @dev called when quoting, to record the quote amount in an error
    /// @dev QuoteSwap is used to differentiate this error from other errors thrown when simulating the swap
    function revertQuote(uint256 quoteAmount) internal pure {
        revert QuoteSwap(quoteAmount);
    }

    /// @notice reverts using the revertData as the reason
    /// @dev to bubble up both the valid QuoteSwap(amount) error, or an alternative error thrown during simulation
    function bubbleReason(bytes memory revertData) internal pure {
        // mload(revertData): the length of the revert data
        // add(revertData, 0x20): a pointer to the start of the revert data
        assembly ("memory-safe") {
            revert(add(revertData, 0x20), mload(revertData))
        }
    }

    /// @notice validates whether a revert reason is a valid swap quote or not
    /// if valid, it decodes the quote to return. Otherwise it reverts.
    function parseQuoteAmount(bytes memory reason) internal pure returns (uint256 quoteAmount) {
        // If the error doesnt start with QuoteSwap, we know this isnt a valid quote to parse
        // Instead it is another revert that was triggered somewhere in the simulation
        if (reason.parseSelector() != QuoteSwap.selector) {
            revert UnexpectedRevertBytes(reason);
        }

        // reason -> reason+0x1f is the length of the reason string
        // reason+0x20 -> reason+0x23 is the selector of QuoteSwap
        // reason+0x24 -> reason+0x43 is the quoteAmount
        assembly ("memory-safe") {
            quoteAmount := mload(add(reason, 0x24))
        }
    }
}
