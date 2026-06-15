// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {LibClone} from "solady/utils/LibClone.sol";

/// @title MarginAccountFactory
/// @author Uniswap Labs
/// @notice Deploys per-user MarginAccount clones deterministically. Each account is a Solady
///         clone-with-immutable-args of a single implementation, with `(owner, manager)` baked
///         into the clone bytecode. The manager (the canonical margin router) is fixed at
///         construction and baked into every clone; it is also bound into the CREATE2 salt, so a
///         new router version ships as a new factory whose accounts get distinct addresses.
/// @custom:security-contact security@uniswap.org
contract MarginAccountFactory {
    /// @notice The MarginAccount implementation that every clone delegates to.
    address public immutable accountImplementation;

    /// @notice The trusted manager (the margin router) baked into every clone this factory deploys.
    address public immutable manager;

    /// @dev Thrown when the constructor is called with a zero implementation or manager address.
    error ZeroAddress();

    /// @notice Emitted when a new account clone is deployed.
    /// @param owner The owner whose address is baked into the clone.
    /// @param account The deployed clone address.
    /// @param subId The sub-account index used in the CREATE2 salt.
    event AccountCreated(address indexed owner, address indexed account, uint256 subId);

    constructor(address accountImplementation_, address manager_) {
        if (accountImplementation_ == address(0) || manager_ == address(0)) revert ZeroAddress();
        accountImplementation = accountImplementation_;
        manager = manager_;
    }

    /// @notice The deterministic address of an owner's account for a given subId, whether or not it
    ///         has been deployed.
    /// @param owner The account owner whose address is encoded in the CREATE2 salt.
    /// @param subId A caller-chosen index allowing one owner to hold multiple independent accounts.
    /// @return The predicted MarginAccount clone address.
    function accountOf(address owner, uint256 subId) public view returns (address) {
        return LibClone.predictDeterministicAddress(
            accountImplementation, _args(owner), _salt(owner, subId), address(this)
        );
    }

    /// @notice Deploys an owner's account for a subId if it does not yet exist, returning its
    ///         address. Idempotent: a repeat call, or a lost lazy-deploy race, returns the existing
    ///         account instead of reverting.
    /// @param owner The owner whose address is baked into the clone and used in the CREATE2 salt.
    /// @param subId The sub-account index. Each distinct subId yields a separate clone.
    /// @return account The deployed (or pre-existing) MarginAccount clone address.
    function createAccount(address owner, uint256 subId) external returns (address account) {
        account = accountOf(owner, subId);
        if (account.code.length == 0) {
            LibClone.cloneDeterministic(accountImplementation, _args(owner), _salt(owner, subId));
            emit AccountCreated(owner, account, subId);
        }
    }

    /// @notice Builds the immutable args baked into a clone: `(owner, manager)`. The manager is
    ///         this factory's canonical manager, so the owner cannot supply a different one.
    /// @param owner The account owner address.
    /// @return ABI-encoded `(owner, manager)`.
    function _args(address owner) internal view returns (bytes memory) {
        return abi.encode(owner, manager);
    }

    /// @notice Builds the CREATE2 salt, binding `owner`, `manager`, and `subId` so addresses are
    ///         distinct per owner, per router version, and per sub-account. Binding `owner` also
    ///         neutralizes address squatting: deploying at someone's predicted address bakes them
    ///         in as owner.
    /// @param owner The account owner address.
    /// @param subId The sub-account index.
    /// @return The keccak256 hash used as the CREATE2 salt.
    function _salt(address owner, uint256 subId) internal view returns (bytes32) {
        return keccak256(abi.encode(owner, manager, subId));
    }
}
