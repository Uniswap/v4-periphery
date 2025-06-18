// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {V4Router, IPoolManager, Currency} from "../../V4Router.sol";
import {ReentrancyLock} from "../../base/ReentrancyLock.sol";
import {
    IWrappedPermissionedTokenFactory,
    IWrappedPermissionedToken
} from "./interfaces/IWrappedPermissionedTokenFactory.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";

contract PermissionedV4Router is V4Router, ReentrancyLock {
    IAllowanceTransfer public immutable PERMIT2;
    IWrappedPermissionedTokenFactory public immutable WRAPPED_TOKEN_FACTORY;

    constructor(
        IPoolManager poolManager_,
        IAllowanceTransfer _permit2,
        IWrappedPermissionedTokenFactory wrappedTokenFactory
    ) V4Router(poolManager_) {
        PERMIT2 = _permit2;
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
        // token is a permissioned token, wrap the token
        IWrappedPermissionedToken wrappedPermissionedToken = IWrappedPermissionedToken(Currency.unwrap(currency));
        PERMIT2.transferFrom(payer, address(wrappedPermissionedToken), uint160(amount), permissionedToken);
        wrappedPermissionedToken.wrapToPoolManager(amount);
    }
}
