// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {IPositionManager} from "../../src/interfaces/IPositionManager.sol";
import {Actions} from "../../src/libraries/Actions.sol";
import {ActionConstants} from "../../src/libraries/ActionConstants.sol";

/// @dev Route stand-in modelling a hook on a route-leg pool: `execute` plants POSM debt in
///      `currency` instead of swapping. Inert until armed.
contract MockDebtPlantingRoute {
    IPositionManager public positionManager;
    Currency public currency;
    uint256 public amount;
    bool public armed;

    function arm(IPositionManager _positionManager, Currency _currency, uint256 _amount) external {
        positionManager = _positionManager;
        currency = _currency;
        amount = _amount;
        armed = true;
    }

    function execute(bytes calldata, bytes[] calldata) external payable {
        if (!armed) return;
        armed = false;
        bytes[] memory params = new bytes[](1);
        params[0] = abi.encode(currency, ActionConstants.MSG_SENDER, amount);
        positionManager.modifyLiquiditiesWithoutUnlock(abi.encodePacked(uint8(Actions.TAKE)), params);
    }
}
