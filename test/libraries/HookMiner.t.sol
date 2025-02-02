// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {HookMiner} from "../../src/libraries/HookMiner.sol";

contract Blank {
    uint256 public num;

    constructor(uint256 _num) {
        num = _num;
    }
}

contract HookMinerTest is Test {
    function test_fuzz_hookMiner(uint16 flags, uint256 number) public {
        (address addr, bytes32 salt) =
            HookMiner.find(address(this), uint160(flags), type(Blank).creationCode, abi.encode(number));

        Blank c = new Blank{salt: salt}(number);

        assertEq(address(c), addr);
        assertEq(c.num(), number);

        // address of the contract has the desired flags
        assertEq(uint160(address(c)) & HookMiner.FLAG_MASK, flags & HookMiner.FLAG_MASK);
    }

    /// @dev not fuzzed because there are certain flags where two unique salts cannot be found in the 160k iterations
    function test_hookMiner_addressCollision() public {
        uint16 flags = uint16(Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG);
        uint256 number = 100;
        (address addr, bytes32 salt) =
            HookMiner.find(address(this), uint160(flags), type(Blank).creationCode, abi.encode(number));
        Blank c = new Blank{salt: salt}(number);
        assertEq(address(c), addr);
        assertEq(c.num(), number);

        // address of the contract has the desired flags
        assertEq(uint160(address(c)) & HookMiner.FLAG_MASK, flags & HookMiner.FLAG_MASK);

        // despite using the same `.find()` parameters, the library skips any addresses with bytecode
        (address newAddress, bytes32 otherSalt) =
            HookMiner.find(address(this), uint160(flags), type(Blank).creationCode, abi.encode(number));
        
        // different salt / address was found
        assertNotEq(newAddress, addr);
        assertNotEq(otherSalt, salt);

        // second contract deploys successfully with the unique salt
        Blank d = new Blank{salt: otherSalt}(number);
        assertEq(address(d), newAddress);
        assertEq(d.num(), number);

        // address of the contract has the desired flags
        assertEq(uint160(address(d)) & HookMiner.FLAG_MASK, flags & HookMiner.FLAG_MASK);
    }
}
