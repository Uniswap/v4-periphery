// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

type PermissionFlag is bytes2;

using {or as |} for PermissionFlag global;
using {and as &} for PermissionFlag global;
using {eq as ==} for PermissionFlag global;

function or(PermissionFlag a, PermissionFlag b) pure returns (PermissionFlag) {
    return PermissionFlag.wrap(PermissionFlag.unwrap(a) | PermissionFlag.unwrap(b));
}

function and(PermissionFlag a, PermissionFlag b) pure returns (PermissionFlag) {
    return PermissionFlag.wrap(PermissionFlag.unwrap(a) & PermissionFlag.unwrap(b));
}

function eq(PermissionFlag a, PermissionFlag b) pure returns (bool) {
    return PermissionFlag.unwrap(a) == PermissionFlag.unwrap(b);
}

library PermissionFlags {
    PermissionFlag constant NONE = PermissionFlag.wrap(0x0000);
    PermissionFlag constant SWAP_ALLOWED = PermissionFlag.wrap(0x0001);
    PermissionFlag constant LIQUIDITY_ALLOWED = PermissionFlag.wrap(0x0002);
    PermissionFlag constant ALL_ALLOWED = PermissionFlag.wrap(0xFFFF);

    function hasFlag(PermissionFlag permissions, PermissionFlag flag) internal pure returns (bool) {
        return PermissionFlag.unwrap(and(permissions, flag)) != 0;
    }
}
