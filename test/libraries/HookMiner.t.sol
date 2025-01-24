// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {HookMiner} from "../../src/libraries/HookMiner.sol";

contract Blank {
    uint256 public num;

    constructor(uint256 _num) {
        num = _num;
    }
}

contract HookMinerTest is Test {
    function test_hookMiner(uint16 flags, uint256 number) public {
        (address addr, bytes32 salt) =
            HookMiner.find(address(this), uint160(flags), type(Blank).creationCode, abi.encode(number));

        Blank c = new Blank{salt: salt}(number);

        assertEq(address(c), addr);
        assertEq(c.num(), number);

        // address of the contract has the desired flags
        assertEq(uint160(address(c)) & HookMiner.FLAG_MASK, flags & HookMiner.FLAG_MASK);
    }

    function test_hookMiner_addressCollision(uint16 flags, uint256 number) public {
        (address addr, bytes32 salt) =
            HookMiner.find(address(this), uint160(flags), type(Blank).creationCode, abi.encode(number));
        Blank c = new Blank{salt: salt}(number);
        assertEq(address(c), addr);
        assertEq(c.num(), number);

        // address of the contract has the desired flags
        assertEq(uint160(address(c)) & HookMiner.FLAG_MASK, flags & HookMiner.FLAG_MASK);

        // count the number of bits in flags
        uint256 bitCount;
        for (uint256 i = 0; i < 14; i++) {
            if ((flags >> i) & 1 == 1) {
                bitCount++;
            }
        }

        // only check for collision, if there are less than 8 bits
        // (HookMiner struggles to find two valid salts within 160k iterations)
        if (bitCount <= 8) {
            // despite using the same `.find()` parameters, the library skips any addresses with bytecode
            (address newAddress, bytes32 otherSalt) =
                HookMiner.find(address(this), uint160(flags), type(Blank).creationCode, abi.encode(number));
            assertNotEq(newAddress, addr);
            assertNotEq(otherSalt, salt);
            Blank d = new Blank{salt: otherSalt}(number);
            assertEq(address(d), newAddress);
            assertEq(d.num(), number);

            // address of the contract has the desired flags
            assertEq(uint160(address(d)) & HookMiner.FLAG_MASK, flags & HookMiner.FLAG_MASK);
        }
    }
}
