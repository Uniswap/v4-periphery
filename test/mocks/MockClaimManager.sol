// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {V4Router} from "../../src/V4Router.sol";
import {ReentrancyLock} from "../../src/base/ReentrancyLock.sol";
import {ImmutableState} from "../../src/base/ImmutableState.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {DeltaResolver} from "../../src/base/DeltaResolver.sol";
import {SafeTransferLib} from "solmate/src/utils/SafeTransferLib.sol";
import {ERC20} from "solmate/src/tokens/ERC20.sol";

contract MockClaimManager is DeltaResolver, IUnlockCallback {
    constructor(IPoolManager _poolManager) ImmutableState(_poolManager) {}

    function mint(Currency currency, uint256 amount) external {
        poolManager.unlock(abi.encode(currency, msg.sender, amount));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        (Currency currency, address caller, uint256 amount) = abi.decode(data, (Currency, address, uint256));
        _settle(currency, caller, amount);
        poolManager.mint(caller, currency.toId(), amount);

        return "";
    }

    function _pay(Currency token, address payer, uint256 amount) internal override {
        ERC20(Currency.unwrap(token)).transferFrom(payer, address(poolManager), amount);
    }

    // needs to receive native tokens from the `take` call
    receive() external payable {}
}
