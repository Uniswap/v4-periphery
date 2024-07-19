// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.24;

import {BaseActionsRouter} from "../../src/base/BaseActionsRouter.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

contract MockBaseActionsRouter is BaseActionsRouter {
    uint256 public swapCount;
    uint256 public increaseLiqCount;
    uint256 public decreaseLiqCount;
    uint256 public donateCount;
    uint256 public clearCount;
    uint256 public settleCount;
    uint256 public takeCount;
    uint256 public mintCount;
    uint256 public burnCount;

    constructor(IPoolManager poolManager) BaseActionsRouter(poolManager) {}

    function executeAction(bytes calldata params) external {
        _executeActions(params);
    }

    function _settle(bytes memory /* params **/ ) internal override {
        settleCount++;
    }

    function _take(bytes memory /* params **/ ) internal override {
        takeCount++;
    }

    function _swap(bytes memory /* params **/ ) internal override {
        swapCount++;
    }

    function _increaseLiquidity(bytes memory /* params **/ ) internal override {
        increaseLiqCount++;
    }

    function _decreaseLiquidity(bytes memory /* params **/ ) internal override {
        decreaseLiqCount++;
    }

    function _donate(bytes memory /* params **/ ) internal override {
        donateCount++;
    }

    function _mint6909(bytes memory /* params **/ ) internal override {
        mintCount++;
    }

    function _burn6909(bytes memory /* params **/ ) internal override {
        burnCount++;
    }

    function _clearDelta(bytes memory /* params **/ ) internal override {
        clearCount++;
    }

    function _pay(Currency, /* currency **/ address, /* payer **/ address, /* recipient **/ uint256 /* amount **/ )
        internal
        override
    {}
}
