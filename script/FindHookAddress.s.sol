// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import {CREATE3} from "solmate/src/utils/CREATE3.sol";

contract FindHookAddress is Script {
    // Hook permissions we need: beforeSwap (0x80) + beforeAddLiquidity (0x800) = 0x880
    uint160 constant REQUIRED_BITS = 0x0880;

    function run() external {
        console2.log("Finding CREATE3 salt for address ending in 0880...");
        console2.log("Required bits:", REQUIRED_BITS);

        // Try different salts until we find one that produces the right address
        for (uint256 i = 0; i < 100000; i++) {
            bytes32 salt = bytes32(i);
            // default forge deployer address
            address predicted = CREATE3.getDeployed(salt, address(0x7FA9385bE102ac3EAc297483Dd6233D62b3e1496));

            // Check if the last 14 bits match our required bits
            if (uint160(predicted) & 0xFFFF == REQUIRED_BITS) {
                console2.log("Found matching salt!");
                console2.log("Salt (decimal):", i);
                console2.log("Salt (hex):", vm.toString(salt));
                console2.log("Predicted address:", predicted);
                console2.log("Address (hex):", vm.toString(predicted));

                // Verify the bits
                uint160 lastBits = uint160(predicted) & 0xFFFF;
                console2.log("Last 14 bits:", lastBits);
                console2.log("Last 14 bits (hex):", vm.toString(lastBits));

                return;
            }

            if (i % 10000 == 0) {
                console2.log("Checked", i, "salts...");
            }
        }

        console2.log("No matching salt found in first 100K attempts");
    }
}
