// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";

library BalanceDeltaExtensionLibrary {
    function setAmount0(BalanceDelta a, int128 amount0) internal pure returns (BalanceDelta) {
        assembly {
            // set the upper 128 bits of a to amount0
            a := or(shl(128, amount0), and(sub(shl(128, 1), 1), a))
        }
        return a;
    }

    function setAmount1(BalanceDelta a, int128 amount1) internal pure returns (BalanceDelta) {
        assembly {
            // set the lower 128 bits of a to amount1
            a := or(and(shl(128, sub(shl(128, 1), 1)), a), amount1)
        }
        return a;
    }

    function addAmount0(BalanceDelta a, int128 amount0) internal pure returns (BalanceDelta) {
        assembly {
            let a0 := sar(128, a)
            let res0 := add(a0, amount0)
            a := or(shl(128, res0), and(sub(shl(128, 1), 1), a))
        }
        return a;
    }

    function addAmount1(BalanceDelta a, int128 amount1) internal pure returns (BalanceDelta) {
        assembly {
            let a1 := signextend(15, a)
            let res1 := add(a1, amount1)
            a := or(and(shl(128, sub(shl(128, 1), 1)), a), res1)
        }
        return a;
    }

    function addAndAssign(BalanceDelta a, BalanceDelta b) internal pure returns (BalanceDelta) {
        assembly {
            let a0 := sar(128, a)
            let a1 := signextend(15, a)
            let b0 := sar(128, b)
            let b1 := signextend(15, b)
            let res0 := add(a0, b0)
            let res1 := add(a1, b1)
            a := or(shl(128, res0), and(sub(shl(128, 1), 1), res1))
        }
        return a;
    }
}
