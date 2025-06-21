// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {
    PositionManager,
    PoolKey,
    IPoolManager,
    IAllowanceTransfer,
    IPositionDescriptor,
    IWETH9,
    Currency
} from "../../PositionManager.sol";
import {
    IWrappedPermissionedTokenFactory,
    IWrappedPermissionedToken
} from "./interfaces/IWrappedPermissionedTokenFactory.sol";

contract PermissionedPositionManager is PositionManager {
    IWrappedPermissionedTokenFactory public immutable WRAPPED_TOKEN_FACTORY;
    address public immutable PERMISSIONED_SWAP_ROUTER;

    error InvalidHook();

    /// @dev as this contract and the swap router rely on each others addresses in the constructor, both contracts need
    /// to be deployed using create3 to create deterministic addresses that do not depend on the constructor arguments
    constructor(
        IPoolManager _poolManager,
        IAllowanceTransfer _permit2,
        uint256 _unsubscribeGasLimit,
        IPositionDescriptor _tokenDescriptor,
        IWETH9 _weth9,
        IWrappedPermissionedTokenFactory _wrappedTokenFactory,
        address _permissionedSwapRouter // address needs to be calculated in advance using create3
    ) PositionManager(_poolManager, _permit2, _unsubscribeGasLimit, _tokenDescriptor, _weth9) {
        WRAPPED_TOKEN_FACTORY = _wrappedTokenFactory;
        PERMISSIONED_SWAP_ROUTER = _permissionedSwapRouter;
    }

    /// @dev Disables transfers of the ERC721 liquidity position tokens
    function transferFrom(address, address, uint256) public pure override {
        revert("Transfer disabled");
    }

    function safeTransferFrom(address, address, uint256) public pure override {
        revert("Transfer disabled");
    }

    function safeTransferFrom(address, address, uint256, bytes calldata) public pure override {
        revert("Transfer disabled");
    }

    /// @dev When minting a position, verify that the sender is allowed to mint the position. This prevents a disallowed user from minting one sided liquidity.
    function _mint(
        PoolKey calldata poolKey,
        int24 tickLower,
        int24 tickUpper,
        uint256 liquidity,
        uint128 amount0Max,
        uint128 amount1Max,
        address owner,
        bytes calldata hookData
    ) internal override {
        // allowlist is verified in the hook call
        if (address(poolKey.hooks) != PERMISSIONED_SWAP_ROUTER) revert InvalidHook();
        super._mint(poolKey, tickLower, tickUpper, liquidity, amount0Max, amount1Max, owner, hookData);
    }

    /// @dev When paying to settle, if the currency is a permissioned token, wrap the token and transfer it to the pool manager.
    function _pay(Currency currency, address payer, uint256 amount) internal virtual override {
        address permissionedToken = WRAPPED_TOKEN_FACTORY.verifiedPermissionedTokenOf(Currency.unwrap(currency));
        if (permissionedToken == address(0)) {
            // token is not a permissioned token, use the default implementation
            super._pay(currency, payer, amount);
            return;
        }
        // token is permissioned, wrap the token and transfer it to the pool manager
        IWrappedPermissionedToken wrappedPermissionedToken = IWrappedPermissionedToken(Currency.unwrap(currency));
        if (payer == address(this)) {
            // @audit is it necessary to check the allowlist here?
            if (!wrappedPermissionedToken.isAllowed(msgSender())) {
                revert Unauthorized();
            }
            currency.transfer(address(wrappedPermissionedToken), amount);
            wrappedPermissionedToken.wrapToPoolManager(amount);
        } else {
            // token is a permissioned token, wrap the token
            permit2.transferFrom(payer, address(wrappedPermissionedToken), uint160(amount), permissionedToken);
            wrappedPermissionedToken.wrapToPoolManager(amount);
        }
    }
}
