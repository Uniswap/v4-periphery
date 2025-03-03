// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {DeltaResolver} from "../../src/base/DeltaResolver.sol";
import {ImmutableState} from "../../src/base/ImmutableState.sol";
import {ERC20} from "solmate/src/tokens/ERC20.sol";
import {Test} from "forge-std/Test.sol";

contract MockDeltaResolver is Test, DeltaResolver, IUnlockCallback {
    uint256 public payCallCount;

    constructor(IPoolManager _poolManager) ImmutableState(_poolManager) {}

    function executeTest(Currency currency, uint256 amount) external {
        poolManager.unlock(abi.encode(currency, msg.sender, amount));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        (Currency currency, address caller, uint256 amount) = abi.decode(data, (Currency, address, uint256));
        address recipient = (currency.isAddressZero()) ? address(this) : caller;

        uint256 balanceBefore = currency.balanceOf(recipient);
        _take(currency, recipient, amount);
        uint256 balanceAfter = currency.balanceOf(recipient);

        assertEq(balanceBefore + amount, balanceAfter);

        balanceBefore = balanceAfter;
        _settle(currency, recipient, amount);
        balanceAfter = currency.balanceOf(recipient);

        assertEq(balanceBefore - amount, balanceAfter);

        return "";
    }

    function _pay(Currency token, address payer, uint256 amount) internal override {
        ERC20(Currency.unwrap(token)).transferFrom(payer, address(poolManager), amount);
        payCallCount++;
    }

    // needs to receive native tokens from the `take` call
    receive() external payable {}
}
