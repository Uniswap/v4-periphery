// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import {MiddlewareRemove} from "../../src/middleware/MiddlewareRemove.sol";
import {MiddlewareRemoveNoDeltas} from "../../src/middleware/MiddlewareRemoveNoDeltas.sol";

/// @title MiddlewareMiner - a library for mining middleware addresses
/// @dev This library is intended for `forge test` environments. There may be gotchas when using salts in `forge script` or `forge create`
library MiddlewareMiner {
    // mask to slice out the bottom 14 bit of the address
    uint160 constant FLAG_MASK = 0x3FFF;

    /// @notice Find a salt that produces a hook address with the desired `flags`
    /// @param factory The factory address that will deploy the hook.
    /// @param flags The desired flags for the hook address
    /// @param manager The pool manager
    /// @param implementation The implementation address
    /// @param maxFeeBips The max fee in bips
    /// @return hookAddress salt and corresponding address that was found. The salt can be used in `new Hook{salt: salt}(<constructor arguments>)`
    function find(address factory, uint160 flags, address manager, address implementation, uint256 maxFeeBips)
        internal
        view
        returns (address, bytes32)
    {
        bytes memory creationCodeWithArgs;
        if (maxFeeBips == 0) {
            creationCodeWithArgs =
                abi.encodePacked(type(MiddlewareRemoveNoDeltas).creationCode, abi.encode(manager, implementation));
        } else {
            creationCodeWithArgs =
                abi.encodePacked(type(MiddlewareRemove).creationCode, abi.encode(manager, implementation, maxFeeBips));
        }
        address hookAddress;

        uint256 salt = uint256(keccak256(abi.encode(implementation)));
        while (true) {
            hookAddress = computeAddress(factory, salt, creationCodeWithArgs);
            if (uint160(hookAddress) & FLAG_MASK == flags && hookAddress.code.length == 0) {
                return (hookAddress, bytes32(salt));
            }
            unchecked {
                ++salt;
            }
        }
        revert("HookMiner: could not find salt");
    }

    /// @notice Precompute a contract address deployed via CREATE2
    /// @param factory The address that will deploy the hook. In `forge test`, this will be the test contract `address(this)` or the pranking address
    ///                 In `forge script`, this should be `0x4e59b44847b379578588920cA78FbF26c0B4956C` (CREATE2 factory Proxy)
    /// @param salt The salt used to deploy the hook
    /// @param creationCode The creation code of a hook contract
    function computeAddress(address factory, uint256 salt, bytes memory creationCode)
        internal
        pure
        returns (address hookAddress)
    {
        return
            address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xFF), factory, salt, keccak256(creationCode))))));
    }
}
