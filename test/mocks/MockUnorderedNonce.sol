// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {UnorderedNonce} from "../../src/base/UnorderedNonce.sol";

contract MockUnorderedNonce is UnorderedNonce {
    function spendNonce(address owner, uint256 nonce) external {
        _useUnorderedNonce(owner, nonce);
    }

    /// @dev Bulk-spend nonces on a single word. FOR TESTING ONLY
    function batchSpendNonces(uint256 wordPos, uint256 mask) external {
        nonces[msg.sender][wordPos] |= mask;
    }
}
