// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import {CREATE3} from "solmate/src/utils/CREATE3.sol";

contract FindHookAddress is Script {
    // Hook permissions we need: beforeSwap (0x80) + beforeAddLiquidity (0x800) = 0x880
    uint160 constant REQUIRED_BITS = 0x880;
    
    function run() external {
        console2.log("Finding CREATE3 salt for address ending in 0880...");
        console2.log("Required bits:", REQUIRED_BITS);
        
        // Try different salts until we find one that produces the right address
        for (uint256 i = 0; i < 1000000; i++) {
            bytes32 salt = bytes32(i);
            address predicted = CREATE3.getDeployed(salt);
            
            // Check if the last 14 bits match our required bits
            if (uint160(predicted) & 0x3FFF == REQUIRED_BITS) {
                console2.log("Found matching salt!");
                console2.log("Salt (decimal):", i);
                console2.log("Salt (hex):", vm.toString(salt));
                console2.log("Predicted address:", predicted);
                console2.log("Address (hex):", vm.toString(predicted));
                
                // Verify the bits
                uint160 lastBits = uint160(predicted) & 0x3FFF;
                console2.log("Last 14 bits:", lastBits);
                console2.log("Last 14 bits (hex):", vm.toString(lastBits));
                
                return;
            }
            
            if (i % 100000 == 0) {
                console2.log("Checked", i, "salts...");
            }
        }
        
        console2.log("No matching salt found in first 1M attempts");
    }
} 