//SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {ERC20} from "solmate/src/tokens/ERC20.sol";
import {DeltaResolver} from "../src/base/DeltaResolver.sol";
import {ActionConstants} from "../src/libraries/ActionConstants.sol";
import {MockDeltaResolver} from "./mocks/MockDeltaResolver.sol";

contract DeltaResolverTest is Test, Deployers {
    MockDeltaResolver resolver;

    // Execution modes mirrored from MockDeltaResolver
    uint8 internal constant MODE_DEBT_AFTER_TAKE = 1;
    uint8 internal constant MODE_FORCE_CREDIT = 2;
    uint8 internal constant MODE_DEBT_REVERT_ON_CREDIT = 3;
    uint8 internal constant MODE_CREDIT_REVERT_ON_DEBT = 4;
    uint8 internal constant MODE_MAP_SETTLE_OPEN_DELTA = 5;
    uint8 internal constant MODE_MAP_TAKE_OPEN_DELTA = 6;
    uint8 internal constant MODE_MAP_WRAP_UNWRAP_OPEN_DELTA = 7;

    function setUp() public {
        initializeManagerRoutersAndPoolsWithLiq(IHooks(address(0)));
        resolver = new MockDeltaResolver(manager);
    }

    function test_settle_native_succeeds(uint256 amount) public {
        amount = bound(amount, 1, address(manager).balance);

        resolver.executeTest(CurrencyLibrary.ADDRESS_ZERO, amount);

        // check `pay` was not called
        assertEq(resolver.payCallCount(), 0);
    }

    function test_settle_token_succeeds(uint256 amount) public {
        amount = bound(amount, 1, currency0.balanceOf(address(manager)));

        // the tokens will be taken to this contract, so an approval is needed for the settle
        ERC20(Currency.unwrap(currency0)).approve(address(resolver), type(uint256).max);

        resolver.executeTest(currency0, amount);

        // check `pay` was called
        assertEq(resolver.payCallCount(), 1);
    }

    function test_take_amount_zero_returns_early() public {
        // _take should no-op on zero amount
        resolver.exposed_take(currency0, address(this), 0);
    }

    function test_settle_amount_zero_returns_early_native() public {
        // _settle should no-op on zero amount
        uint256 payCallsBefore = resolver.payCallCount();

        resolver.exposed_settle(CurrencyLibrary.ADDRESS_ZERO, address(this), 0);

        assertEq(resolver.payCallCount(), payCallsBefore);
    }

    function test_settle_amount_zero_returns_early_token() public {
        uint256 payCallsBefore = resolver.payCallCount();

        resolver.exposed_settle(currency0, address(this), 0);

        assertEq(resolver.payCallCount(), payCallsBefore);
    }

    function test_getFullDebt_returns_after_take(uint256 amount) public {
        // Negative delta created via take, then queried inside unlock context
        amount = bound(amount, 1, currency0.balanceOf(address(manager)));

        bytes memory data = resolver.executeMode(
            MODE_DEBT_AFTER_TAKE, currency0, amount, CurrencyLibrary.ADDRESS_ZERO, CurrencyLibrary.ADDRESS_ZERO
        );

        uint256 debt = abi.decode(data, (uint256));
        assertEq(debt, amount);
    }

    function test_getFullDebt_reverts_when_credit_positive(uint256 amount) public {
        // Reading debt when delta is positive should revert
        amount = bound(amount, 1, 1e18);

        vm.expectRevert(abi.encodeWithSelector(DeltaResolver.DeltaNotNegative.selector, currency0));
        resolver.executeMode(
            MODE_DEBT_REVERT_ON_CREDIT, currency0, amount, CurrencyLibrary.ADDRESS_ZERO, CurrencyLibrary.ADDRESS_ZERO
        );
    }

    function test_getFullCredit_returns_after_force_credit(uint256 amount) public {
        // Positive delta is injected via transient state mock
        amount = bound(amount, 1, 1e18);

        bytes memory data = resolver.executeMode(
            MODE_FORCE_CREDIT, currency0, amount, CurrencyLibrary.ADDRESS_ZERO, CurrencyLibrary.ADDRESS_ZERO
        );

        uint256 credit = abi.decode(data, (uint256));
        assertEq(credit, amount);
    }

    function test_getFullCredit_reverts_when_debt_negative(uint256 amount) public {
        // Reading credit when delta is negative should revert
        amount = bound(amount, 1, currency0.balanceOf(address(manager)));

        vm.expectRevert(abi.encodeWithSelector(DeltaResolver.DeltaNotPositive.selector, currency0));
        resolver.executeMode(
            MODE_CREDIT_REVERT_ON_DEBT, currency0, amount, CurrencyLibrary.ADDRESS_ZERO, CurrencyLibrary.ADDRESS_ZERO
        );
    }

    function test_mapSettleAmount_contract_balance_token(uint256 balance) public {
        // CONTRACT_BALANCE resolves to resolver's token balance
        balance = bound(balance, 0, 1e18);
        deal(Currency.unwrap(currency0), address(resolver), balance);

        uint256 mapped = resolver.exposed_mapSettleAmount(ActionConstants.CONTRACT_BALANCE, currency0);
        assertEq(mapped, balance);
    }

    function test_mapSettleAmount_literal_passthrough(uint256 amount) public view {
        // Literal amounts pass through unchanged
        amount = bound(amount, 0, type(uint128).max);

        uint256 mapped = resolver.exposed_mapSettleAmount(amount, currency0);
        assertEq(mapped, amount);
    }

    function test_mapSettleAmount_open_delta_uses_debt(uint256 amount) public {
        // OPEN_DELTA resolves to full debt
        amount = bound(amount, 1, currency0.balanceOf(address(manager)));

        bytes memory data = resolver.executeMode(
            MODE_MAP_SETTLE_OPEN_DELTA, currency0, amount, CurrencyLibrary.ADDRESS_ZERO, CurrencyLibrary.ADDRESS_ZERO
        );

        uint256 mapped = abi.decode(data, (uint256));
        assertEq(mapped, amount);
    }

    function test_mapTakeAmount_literal_passthrough(uint256 amount) public view {
        amount = bound(amount, 0, type(uint128).max);

        uint256 mapped = resolver.exposed_mapTakeAmount(amount, currency0);
        assertEq(mapped, amount);
    }

    function test_mapTakeAmount_open_delta_uses_credit(uint256 amount) public {
        // OPEN_DELTA resolves to full credit
        amount = bound(amount, 1, 1e18);

        bytes memory data = resolver.executeMode(
            MODE_MAP_TAKE_OPEN_DELTA, currency0, amount, CurrencyLibrary.ADDRESS_ZERO, CurrencyLibrary.ADDRESS_ZERO
        );

        uint256 mapped = abi.decode(data, (uint256));
        assertEq(mapped, amount);
    }

    function test_mapWrapUnwrapAmount_contract_balance_token(uint256 balance) public {
        // CONTRACT_BALANCE returns resolver's balance before wrap/unwrap
        balance = bound(balance, 0, 1e18);
        deal(Currency.unwrap(currency0), address(resolver), balance);

        uint256 mapped = resolver.exposed_mapWrapUnwrapAmount(currency0, ActionConstants.CONTRACT_BALANCE, currency0);
        assertEq(mapped, balance);
    }

    function test_mapWrapUnwrapAmount_literal_amount_ok(uint256 amount) public {
        amount = bound(amount, 0, 1e18);
        deal(Currency.unwrap(currency0), address(resolver), amount);

        uint256 mapped = resolver.exposed_mapWrapUnwrapAmount(currency0, amount, currency0);
        assertEq(mapped, amount);
    }

    function test_mapWrapUnwrapAmount_reverts_insufficient_balance(uint256 amount) public {
        // Amount larger than resolver balance should revert
        amount = bound(amount, 1, 1e18);
        deal(Currency.unwrap(currency0), address(resolver), amount - 1);

        vm.expectRevert(DeltaResolver.InsufficientBalance.selector);
        resolver.exposed_mapWrapUnwrapAmount(currency0, amount, currency0);
    }

    function test_mapWrapUnwrapAmount_open_delta_uses_output_debt_and_checks_input_balance(uint256 amount) public {
        // OPEN_DELTA resolves using debt in output currency,
        // while checking balance in input currency
        amount = bound(amount, 1, currency0.balanceOf(address(manager)));
        deal(Currency.unwrap(currency0), address(resolver), amount);

        bytes memory data =
            resolver.executeMode(MODE_MAP_WRAP_UNWRAP_OPEN_DELTA, currency0, amount, currency0, currency0);

        uint256 mapped = abi.decode(data, (uint256));
        assertEq(mapped, amount);
    }
}
