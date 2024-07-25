// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.24;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {BaseActionsRouter} from "../../src/base/BaseActionsRouter.sol";
import {Actions} from "../../src/libraries/Actions.sol";
import {ReentrancyLock} from "../../src/base/ReentrancyLock.sol";
import {Locker} from "../../src/libraries/Locker.sol";

contract MockBaseActionsRouter is BaseActionsRouter, ReentrancyLock {
    uint256 public swapCount;
    uint256 public increaseLiqCount;
    uint256 public decreaseLiqCount;
    uint256 public donateCount;
    uint256 public clearCount;
    uint256 public settleCount;
    uint256 public takeCount;
    uint256 public mintCount;
    uint256 public burnCount;

    constructor(IPoolManager _poolManager) BaseActionsRouter(_poolManager) {}

    function executeAction(bytes calldata params) external isNotLocked {
        _executeActions(params);
    }

    function _handleAction(uint256 action, bytes calldata params) internal override {
        if (action < Actions.SETTLE) {
            if (action == Actions.SWAP) _swap(params);
            else if (action == Actions.INCREASE_LIQUIDITY) _increaseLiquidity(params);
            else if (action == Actions.DECREASE_LIQUIDITY) _decreaseLiquidity(params);
            else if (action == Actions.DONATE) _donate(params);
            else revert UnsupportedAction(action);
        } else {
            if (action == Actions.SETTLE) _settle(params);
            else if (action == Actions.TAKE) _take(params);
            else if (action == Actions.CLEAR) _clear(params);
            else if (action == Actions.MINT_6909) _mint6909(params);
            else if (action == Actions.BURN_6909) _burn6909(params);
            else revert UnsupportedAction(action);
        }
    }

    function _msgSender() internal view override returns (address) {
        return Locker.get();
    }

    function _settle(bytes calldata /* params **/ ) internal {
        settleCount++;
    }

    function _take(bytes calldata /* params **/ ) internal {
        takeCount++;
    }

    function _swap(bytes calldata /* params **/ ) internal {
        swapCount++;
    }

    function _increaseLiquidity(bytes calldata /* params **/ ) internal {
        increaseLiqCount++;
    }

    function _decreaseLiquidity(bytes calldata /* params **/ ) internal {
        decreaseLiqCount++;
    }

    function _donate(bytes calldata /* params **/ ) internal {
        donateCount++;
    }

    function _mint6909(bytes calldata /* params **/ ) internal {
        mintCount++;
    }

    function _burn6909(bytes calldata /* params **/ ) internal {
        burnCount++;
    }

    function _clear(bytes calldata /* params **/ ) internal {
        clearCount++;
    }
}
