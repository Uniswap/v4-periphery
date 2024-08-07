// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.20;

import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";

import {Permit2Forwarder} from "../../src/base/Permit2Forwarder.sol";
import {Permit2ImmutableState} from "../../src/base/Permit2ImmutableState.sol";

contract MockPermit2Forwarder is Permit2Forwarder {
    constructor(IAllowanceTransfer _permit2) Permit2Forwarder(_permit2) {}
}
