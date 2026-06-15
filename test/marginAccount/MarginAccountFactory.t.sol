// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {MarginAccount} from "../../src/MarginAccount.sol";
import {MarginAccountFactory} from "../../src/MarginAccountFactory.sol";

contract MarginAccountFactoryTest is Test {
    MarginAccountFactory internal factory;
    address internal impl;
    address internal manager = makeAddr("manager");
    address internal owner = makeAddr("owner");

    function setUp() public {
        impl = address(new MarginAccount());
        factory = new MarginAccountFactory(impl, manager);
    }

    function test_accountOf_matchesDeployedAddress() public {
        address predicted = factory.accountOf(owner, 0);
        address deployed = factory.createAccount(owner, 0);
        vm.snapshotGasLastCall("MarginAccountFactory_createAccount");
        assertEq(deployed, predicted);
        assertGt(deployed.code.length, 0);
    }

    function test_createAccount_isIdempotent() public {
        address first = factory.createAccount(owner, 0);
        address second = factory.createAccount(owner, 0);
        assertEq(first, second);
    }

    function test_createAccount_bakesOwnerAndManagerIntoBytecode() public {
        MarginAccount account = MarginAccount(factory.createAccount(owner, 0));
        assertEq(account.owner(), owner);
        assertEq(account.manager(), manager);
    }

    function test_squattingAtVictimAddress_producesVictimOwnedAccount() public {
        address attacker = makeAddr("attacker");
        address victim = makeAddr("victim");
        // the attacker can deploy the victim's account, but it bakes in the victim as owner
        vm.prank(attacker);
        MarginAccount account = MarginAccount(factory.createAccount(victim, 0));
        assertEq(account.owner(), victim);
        assertEq(account.manager(), manager);
    }

    function test_accountOf_distinctPerSubId() public view {
        assertTrue(factory.accountOf(owner, 0) != factory.accountOf(owner, 1));
    }

    function test_accountOf_distinctAcrossManagers() public {
        MarginAccountFactory other = new MarginAccountFactory(impl, makeAddr("manager2"));
        assertTrue(factory.accountOf(owner, 0) != other.accountOf(owner, 0));
    }

    function testFuzz_accountOf_isDeterministic(address who, uint256 subId) public view {
        assertEq(factory.accountOf(who, subId), factory.accountOf(who, subId));
    }

    function testFuzz_accountOf_distinctPerOwner(address a, address b) public view {
        vm.assume(a != b);
        assertTrue(factory.accountOf(a, 0) != factory.accountOf(b, 0));
    }
}
