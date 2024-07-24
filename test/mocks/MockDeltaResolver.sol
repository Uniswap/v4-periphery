// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.24;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {DeltaResolver} from "../../src/base/DeltaResolver.sol";
import {ImmutableState} from "../../src/base/ImmutableState.sol";
import {ERC20} from "solmate/tokens/ERC20.sol";

contract MockBaseActionsRouter is DeltaResolver {
    constructor(IPoolManager _poolManager) ImmutableState(_poolManager) {}

    function _pay(Currency token, address payer, uint256 amount) internal override {
        ERC20(Currency.unwrap(token)).transferFrom(payer, address(poolManager), amount);
    }
}
