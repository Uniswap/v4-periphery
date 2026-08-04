// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";

import {MarginAccount} from "../src/MarginAccount.sol";

/// @notice Shared CREATE2 constants and init-code helpers for margin deployment and salt mining.
///         Both `MarginRouterInitCode` and `DeployMargin` must use these helpers so create2crunch
///         targets the same init code hash the deploy script actually broadcasts.
abstract contract MarginDeployConfig is Script {
    /// @dev Foundry's CREATE2 Deployer Proxy; must match create2crunch `--factory`.
    address internal constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    /// @dev Salt for the deterministic MarginAccount implementation.
    bytes32 internal constant ACCOUNT_SALT = keccak256("uniswap.margin.MarginAccount.v1");

    /// @dev Canonical Permit2 address, identical on every chain.
    address internal constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    /// @dev Default WETH9 on Ethereum mainnet.
    address internal constant MAINNET_WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    /// @notice Resolves Permit2 and WETH9 the same way for mining and deployment.
    /// @dev On mainnet, unset env vars fall back to the verified canonical addresses. On other
    ///      chains both `PERMIT2` and `WETH9` must be set explicitly.
    function _marginExternalTokenConfig() internal view returns (address permit2, address weth9) {
        if (block.chainid == 1) {
            permit2 = vm.envOr("PERMIT2", PERMIT2);
            weth9 = vm.envOr("WETH9", MAINNET_WETH);
            return (permit2, weth9);
        }

        permit2 = vm.envAddress("PERMIT2");
        weth9 = vm.envAddress("WETH9");
    }

    /// @notice Predicted MarginAccount implementation for `ACCOUNT_SALT`.
    function _predictedAccountImpl() internal view returns (address accountImpl) {
        accountImpl =
            vm.computeCreate2Address(ACCOUNT_SALT, keccak256(type(MarginAccount).creationCode), CREATE2_DEPLOYER);
    }

    /// @notice Init code hash for
    ///         `new MarginRouter{salt: ...}(poolManager, permit2, weth9, accountImpl, owner)`. The
    ///         Universal Router is no longer a constructor arg (callers pass it per swap), so it does
    ///         not affect the router address and is not part of this hash.
    function _marginRouterInitCodeHash(address poolManager, address accountImpl, address owner)
        internal
        view
        returns (bytes32 initCodeHash)
    {
        (address permit2, address weth9) = _marginExternalTokenConfig();
        initCodeHash = keccak256(
            abi.encodePacked(
                vm.getCode("MarginRouter.sol:MarginRouter"), abi.encode(poolManager, permit2, weth9, accountImpl, owner)
            )
        );
    }

    /// @notice CREATE2 address of the router for a mined salt and deployment tuple.
    function _predictedMarginRouter(address poolManager, address owner, bytes32 routerSalt)
        internal
        view
        returns (address router, address accountImpl, bytes32 initCodeHash)
    {
        accountImpl = _predictedAccountImpl();
        initCodeHash = _marginRouterInitCodeHash(poolManager, accountImpl, owner);
        router = vm.computeCreate2Address(routerSalt, initCodeHash, CREATE2_DEPLOYER);
    }
}
