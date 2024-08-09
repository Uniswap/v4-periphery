// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

library VanityAddressLib {
    function betterThan(address first, address second) internal pure returns (bool better) {
        return score(first) > score(second);
    }

    function score(address addr) internal pure returns (uint256 calculatedScore) {
        // 10 points for every leading 0 byte
        // 1 point for every 4 after that
        bytes20 addrBytes = bytes20(addr);

        bool startingZeros = true;
        bool startingFours = true;
        for (uint256 i = 0; i < 20; i++) {
            if (startingZeros && addrBytes[i] == 0x00) {
                calculatedScore += 20;
                continue;
            } else {
                startingZeros = false;
            }
            if (startingFours && addrBytes[i] == 0x44) {
                calculatedScore += 5;
                continue;
            } else {
                startingFours = false;
            }

            if (!startingZeros && !startingFours) {
                // count each nibble separately
                if (addrBytes[i] & 0x0F == 0x04) {
                    calculatedScore += 1;
                }
                if (addrBytes[i] & 0xF0 == 0x40) {
                    calculatedScore += 1;
                }
            }
        }
    }
}
