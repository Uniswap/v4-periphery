// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.19;

import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";

contract PositionManagerImmutableState {
    IAllowanceTransfer public immutable permit2;

    constructor(IAllowanceTransfer _permit2) {
        permit2 = _permit2;
    }
}
