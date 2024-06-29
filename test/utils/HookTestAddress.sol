// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

library HookTestAddress {
    function getHookAddress(uint160 flags) internal pure returns (address hookAddress) {
        hookAddress = address(uint160(flags) ^ (0x4444 << 144));
    }
}
