// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.19;

/// @title HookMiner - a library for mining hook addresses
/// @dev This library is intended for `forge test` environments. There may be gotchas when using salts in `forge script` or `forge create`
library HookMiner {
    // mask to slice out the top 8 bit of the address
    uint160 constant FLAG_MASK = 0xFF << 152;

    // Maximum number of iterations to find a salt, avoid infinite loops
    uint256 constant MAX_LOOP = 10_000;

    /// @notice Find a salt that produces a hook address with the desired `flags`
    /// @param deployer The address that will deploy the hook. In `forge test`, this will be the test contract `address(this)` or the pranking address
    ///                 In `forge script`, this should be `0x4e59b44847b379578588920cA78FbF26c0B4956C` (CREATE2 Deployer Proxy)
    /// @param flags The desired flags for the hook address
    /// @param seed Use 0 for as a default. An optional starting salt when linearly searching for a salt. Useful for finding salts for multiple hooks with the same flags
    /// @param creationCode The creation code of a hook contract. Example: `type(Counter).creationCode`
    /// @param constructorArgs The encoded constructor arguments of a hook contract. Example: `abi.encode(address(manager))`
    /// @return hookAddress salt and corresponding address that was found. The salt can be used in `new Hook{salt: salt}(<constructor arguments>)`
    function find(
        address deployer,
        uint160 flags,
        uint256 seed,
        bytes memory creationCode,
        bytes memory constructorArgs
    ) external pure returns (address, bytes32) {
        address hookAddress;
        bytes memory creationCodeWithArgs = abi.encodePacked(creationCode, constructorArgs);

        uint256 salt = seed;
        for (salt; salt < MAX_LOOP;) {
            hookAddress = computeAddress(deployer, salt, creationCodeWithArgs);
            if (uint160(hookAddress) & FLAG_MASK == flags) {
                return (hookAddress, bytes32(salt));
            }

            unchecked {
                ++salt;
            }
        }
        revert("HookMiner: could not find salt");
    }

    /// @notice Precompute a contract address deployed via CREATE2
    /// @param deployer The address that will deploy the hook. In `forge test`, this will be the test contract `address(this)` or the pranking address
    ///                 In `forge script`, this should be `0x4e59b44847b379578588920cA78FbF26c0B4956C` (CREATE2 Deployer Proxy)
    /// @param salt The salt used to deploy the hook
    /// @param creationCode The creation code of a hook contract
    function computeAddress(address deployer, uint256 salt, bytes memory creationCode)
        public
        pure
        returns (address hookAddress)
    {
        return address(
            uint160(uint256(keccak256(abi.encodePacked(bytes1(0xFF), deployer, salt, keccak256(creationCode)))))
        );
    }
}
