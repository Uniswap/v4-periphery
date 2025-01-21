//SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {ERC20} from "solmate/src/tokens/ERC20.sol";

import {MockDeltaResolver} from "./mocks/MockDeltaResolver.sol";

contract DeltaResolverTest is Test, Deployers {
    MockDeltaResolver resolver;

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
}
