// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {LibClone} from "solady/utils/LibClone.sol";

/// @title MarginAccountFactory
/// @author Uniswap Labs
/// @notice Deterministic deployment and addressing of per-user MarginAccount clones. Designed to be
///         inherited by the contract that manages the accounts (the margin router): the inheriting
///         contract becomes the `manager` baked into every clone, so accounts can only be deployed
///         and driven by the contract that owns this logic.
/// @dev Each account is a Solady clone-with-immutable-args of a single implementation, with
///      (owner, manager) baked into the clone bytecode. The manager is fixed to the inheriting
///      contract's own address and is also bound into the CREATE2 salt, so an account address is a
///      pure function of (owner, manager, subId).
abstract contract MarginAccountFactory {
    /// @notice The MarginAccount implementation every clone delegates to.
    address public immutable accountImplementation;

    /// @notice The trusted manager baked into every clone. Equal to this contract's own address.
    address public immutable manager;

    /// @dev Thrown when constructed with a zero implementation address, which would make every
    ///      clone delegate to nothing.
    error ZeroAddress();

    /// @notice Emitted when an account clone is deployed.
    /// @param owner The owner baked into the deployed account.
    /// @param account The address of the deployed account clone.
    /// @param subId The sub-account index used to derive the account address.
    event AccountCreated(address indexed owner, address indexed account, uint256 subId);

    /// @param accountImplementation_ The MarginAccount implementation that clones delegate to.
    constructor(address accountImplementation_) {
        if (accountImplementation_ == address(0)) revert ZeroAddress();
        accountImplementation = accountImplementation_;
        manager = address(this);
    }

    /// @notice The deterministic address of an owner's account for a given subId, whether or not it
    ///         has been deployed.
    /// @param owner The account owner baked into the clone.
    /// @param subId The sub-account index, allowing one owner to hold multiple independent accounts.
    /// @return The CREATE2 address of the (owner, manager, subId) account clone.
    function accountOf(address owner, uint256 subId) public view virtual returns (address) {
        return LibClone.predictDeterministicAddress(
            accountImplementation, _args(owner), _salt(owner, subId), address(this)
        );
    }

    /// @notice Deploys an owner's account for a subId if it does not yet exist, returning its
    ///         address. Idempotent: a repeat call, or a lost lazy-deploy race, returns the existing
    ///         account instead of reverting.
    /// @param owner The account owner to bake into the clone.
    /// @param subId The sub-account index.
    /// @return account The deployed (or already-existing) account address.
    function createAccount(address owner, uint256 subId) public virtual returns (address account) {
        account = accountOf(owner, subId);
        if (account.code.length == 0) {
            LibClone.cloneDeterministic(accountImplementation, _args(owner), _salt(owner, subId));
            emit AccountCreated(owner, account, subId);
        }
    }

    /// @notice The immutable args baked into a clone: (owner, manager). The manager is this
    ///         contract's address, so the owner cannot choose it.
    /// @param owner The account owner.
    /// @return The abi-encoded (owner, manager) immutable args.
    function _args(address owner) internal view returns (bytes memory) {
        return abi.encode(owner, manager);
    }

    /// @notice The CREATE2 salt, binding owner, manager, and subId so addresses are distinct per
    ///         owner, per manager, and per sub-account. Binding owner also neutralizes address
    ///         squatting: deploying at someone's predicted address bakes them in as the owner.
    /// @param owner The account owner.
    /// @param subId The sub-account index.
    /// @return The CREATE2 salt for this account.
    function _salt(address owner, uint256 subId) internal view returns (bytes32) {
        return keccak256(abi.encode(owner, manager, subId));
    }
}
