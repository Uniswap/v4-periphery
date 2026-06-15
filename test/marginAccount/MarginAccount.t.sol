// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {LibClone} from "solady/utils/LibClone.sol";

import {MarginAccount} from "../../src/MarginAccount.sol";
import {IMarginAccount} from "../../src/interfaces/IMarginAccount.sol";
import {Market} from "../../src/types/Market.sol";
import {MockLendingAdapter} from "../mocks/MockLendingAdapter.sol";
import {MockLendingProtocol} from "../mocks/MockLendingProtocol.sol";

// records whether it was called by regular call (slot lives in its own storage) so a delegatecall
// from the account would instead write the account's storage, which the test asserts does not happen
contract StorageProbe {
    uint256 public slot0;

    function poke() external {
        slot0 = 42;
    }
}

contract MarginAccountTest is Test {
    MockERC20 internal collateralToken;
    MockERC20 internal debtToken;
    MockLendingProtocol internal protocol;
    MockLendingAdapter internal adapter;
    MarginAccount internal account;

    address internal owner = makeAddr("owner");
    address internal manager = makeAddr("manager");
    address internal stranger = makeAddr("stranger");

    Market internal market;

    function setUp() public {
        collateralToken = new MockERC20("Collateral", "COL", 18);
        debtToken = new MockERC20("Debt", "DEBT", 18);
        protocol = new MockLendingProtocol(IERC20(address(collateralToken)), IERC20(address(debtToken)));
        adapter = new MockLendingAdapter(address(protocol));

        address impl = address(new MarginAccount());
        account = MarginAccount(LibClone.cloneDeterministic(impl, abi.encode(owner, manager), keccak256("acct")));

        market = Market({collateral: Currency.wrap(address(collateralToken)), debt: Currency.wrap(address(debtToken))});

        collateralToken.mint(address(account), 100e18);
        debtToken.mint(address(account), 100e18);
        collateralToken.mint(address(protocol), 1_000e18);
        debtToken.mint(address(protocol), 1_000e18);
    }

    function test_owner_and_manager_readFromImmutableArgs() public view {
        assertEq(account.owner(), owner);
        assertEq(account.manager(), manager);
    }

    function test_supplyCollateral_byManager_succeeds() public {
        vm.prank(manager);
        account.supplyCollateral(adapter, market, 10e18);
        assertEq(protocol.collateralOf(address(account)), 10e18);
        assertEq(collateralToken.balanceOf(address(account)), 90e18);
    }

    function test_supplyCollateral_byOwner_succeeds() public {
        vm.prank(owner);
        account.supplyCollateral(adapter, market, 10e18);
        assertEq(protocol.collateralOf(address(account)), 10e18);
    }

    function test_supplyCollateral_passesAccountAsOnBehalf() public {
        vm.prank(manager);
        account.supplyCollateral(adapter, market, 10e18);
        // the account always passes itself as onBehalf, never an adapter-chosen address
        assertEq(protocol.lastAccount(), address(account));
    }

    function test_supplyCollateral_revertsWhenCallerNotManagerOrOwner() public {
        vm.prank(stranger);
        vm.expectRevert(IMarginAccount.NotAuthorized.selector);
        account.supplyCollateral(adapter, market, 10e18);
    }

    function testFuzz_primitives_revertForUnauthorizedCaller(address caller) public {
        vm.assume(caller != owner && caller != manager);
        vm.prank(caller);
        vm.expectRevert(IMarginAccount.NotAuthorized.selector);
        account.supplyCollateral(adapter, market, 1e18);
    }

    function test_borrow_toManager_succeeds() public {
        vm.prank(manager);
        account.borrow(adapter, market, 5e18, manager);
        vm.snapshotGasLastCall("MarginAccount_borrow");
        assertEq(debtToken.balanceOf(manager), 5e18);
        assertEq(protocol.lastReceiver(), manager);
    }

    function test_borrow_revertsWhenReceiverNotAllowed() public {
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(IMarginAccount.ReceiverNotAllowed.selector, stranger));
        account.borrow(adapter, market, 5e18, stranger);
    }

    function test_withdrawCollateral_revertsWhenReceiverNotAllowed() public {
        // give the account a collateral position to withdraw from
        vm.prank(manager);
        account.supplyCollateral(adapter, market, 10e18);
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(IMarginAccount.ReceiverNotAllowed.selector, stranger));
        account.withdrawCollateral(adapter, market, 1e18, stranger);
    }

    function test_repay_max_repaysOwedAndReturnsAmount() public {
        protocol.setDebt(address(account), 7e18);
        vm.prank(manager);
        uint256 repaid = account.repay(adapter, market, type(uint256).max);
        vm.snapshotGasLastCall("MarginAccount_repay");
        assertEq(repaid, 7e18);
        assertEq(protocol.debtOf(address(account)), 0);
        assertEq(debtToken.balanceOf(address(account)), 93e18);
    }

    function test_sweep_toOwner_succeeds() public {
        vm.prank(owner);
        account.sweep(Currency.wrap(address(collateralToken)), 3e18, owner);
        assertEq(collateralToken.balanceOf(owner), 3e18);
    }

    function test_sweep_revertsWhenReceiverNotAllowed() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IMarginAccount.ReceiverNotAllowed.selector, stranger));
        account.sweep(Currency.wrap(address(collateralToken)), 1e18, stranger);
    }

    function test_targetConstraint_revertsWhenEncodedTargetIsNotLendingProtocol() public {
        adapter.setForcedTarget(address(0xBEEF));
        vm.prank(manager);
        vm.expectRevert(MarginAccount.TargetNotLendingProtocol.selector);
        account.supplyCollateral(adapter, market, 1e18);
    }

    function test_execute_ownerOnly_callsTargetWithoutDelegatecall() public {
        StorageProbe probe = new StorageProbe();
        MockLendingAdapter probeAdapter = new MockLendingAdapter(address(probe));

        vm.prank(owner);
        account.execute(probeAdapter, market, abi.encodeWithSignature("poke()"));

        // regular call: the probe's own storage changed, the account's did not
        assertEq(uint256(vm.load(address(probe), 0)), 42);
        assertEq(uint256(vm.load(address(account), 0)), 0);
    }

    function test_execute_revertsForManager() public {
        StorageProbe probe = new StorageProbe();
        MockLendingAdapter probeAdapter = new MockLendingAdapter(address(probe));
        vm.prank(manager);
        vm.expectRevert(IMarginAccount.NotAuthorized.selector);
        account.execute(probeAdapter, market, abi.encodeWithSignature("poke()"));
    }
}
