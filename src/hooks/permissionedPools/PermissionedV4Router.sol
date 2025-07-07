// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IMsgSender} from "../../interfaces/IMsgSender.sol";
import {ActionConstants} from "../../libraries/ActionConstants.sol";
import {ReentrancyLock} from "../../base/ReentrancyLock.sol";
import {V4Router, IPoolManager, Currency} from "../../V4Router.sol";
import {
    IWrappedPermissionedTokenFactory,
    IWrappedPermissionedToken
} from "./interfaces/IWrappedPermissionedTokenFactory.sol";
import {PermissionedHooks} from "./PermissionedHooks.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Hooks, IHooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";

contract PermissionedV4Router is V4Router, ReentrancyLock {
    IAllowanceTransfer public immutable PERMIT2;
    IWrappedPermissionedTokenFactory public immutable WRAPPED_TOKEN_FACTORY;

    error Unauthorized();
    error HookNotImplemented();

    constructor(
        IPoolManager poolManager_,
        IAllowanceTransfer permit2,
        IWrappedPermissionedTokenFactory wrappedTokenFactory
    ) V4Router(poolManager_) {
        PERMIT2 = permit2;
        WRAPPED_TOKEN_FACTORY = wrappedTokenFactory;
    }

    function execute(bytes calldata input) public payable isNotLocked {
        _executeActions(input);
    }

    /// @notice Public view function to be used instead of msg.sender, as the contract performs self-reentrancy and at
    /// times msg.sender == address(this). Instead msgSender() returns the initiator of the lock
    /// @dev overrides BaseActionsRouter.msgSender in V4Router
    function msgSender() public view override returns (address) {
        return _getLocker();
    }

    function _pay(Currency currency, address payer, uint256 amount) internal override {
        address permissionedToken = WRAPPED_TOKEN_FACTORY.verifiedPermissionedTokenOf(Currency.unwrap(currency));
        if (permissionedToken == address(0)) {
            // token is not a permissioned token, use the default implementation
            if (payer == address(this)) {
                currency.transfer(address(poolManager), amount);
            } else {
                // Casting from uint256 to uint160 is safe due to limits on the total supply of a pool
                PERMIT2.transferFrom(payer, address(poolManager), uint160(amount), Currency.unwrap(currency));
            }
            return;
        }
        // token is permissioned, wrap the token and transfer it to the pool manager
        IWrappedPermissionedToken wrappedPermissionedToken = IWrappedPermissionedToken(Currency.unwrap(currency));
        if (payer == address(this)) {
            // allowlist check necessary to ensure a disallowed user cannot sell a permissioned token
            if (!wrappedPermissionedToken.isAllowed(msgSender())) {
                revert Unauthorized();
            }
            Currency.wrap(permissionedToken).transfer(address(wrappedPermissionedToken), amount);
            wrappedPermissionedToken.wrapToPoolManager(amount);
        } else {
            // token is a permissioned token, wrap the token
            PERMIT2.transferFrom(payer, address(wrappedPermissionedToken), uint160(amount), permissionedToken);
            wrappedPermissionedToken.wrapToPoolManager(amount);
        }
    }

    /// @notice Calculates the amount for a settle action
    function _mapSettleAmount(uint256 amount, Currency currency) internal view override returns (uint256) {
        address permissionedToken = WRAPPED_TOKEN_FACTORY.verifiedPermissionedTokenOf(Currency.unwrap(currency));
        // use the default implementation unless the currency is a permissioned token with a balance on the router
        if (permissionedToken == address(0) || amount != ActionConstants.CONTRACT_BALANCE) {
            return super._mapSettleAmount(amount, currency);
        }
        return Currency.wrap(permissionedToken).balanceOfSelf();
    }

    fallback() external payable {}
    receive() external payable {}
}
