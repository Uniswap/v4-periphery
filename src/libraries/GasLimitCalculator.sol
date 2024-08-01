// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.24;

// TODO: Post-audit move to core, as v4-core will use something similar.
library GasLimitCalculator {
    uint256 constant BPS_DENOMINATOR = 10_000;

    /// calculates a gas limit as a percentage of the currenct block's gas limit
    function toGasLimit(uint256 bps) internal returns (uint256 gasLimit) {
        return block.gaslimit * bps / BPS_DENOMINATOR;
    }
}
