// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {LibClone} from "solady/utils/LibClone.sol";

/// @notice Deploys per-user MarginAccount clones deterministically. Each account is a Solady
///         clone-with-immutable-args of a single implementation, with (owner, manager) baked into
///         the clone bytecode. The manager (the canonical margin router) is fixed at construction
///         and baked into every clone, and it is also bound into the CREATE2 salt, so a new router
///         version ships as a new factory whose accounts get distinct addresses.
contract MarginAccountFactory {
    /// @notice The MarginAccount implementation every clone delegates to.
    address public immutable accountImplementation;

    /// @notice The trusted manager (the margin router) baked into every clone this factory deploys.
    address public immutable manager;

    /// @notice Emitted when an account clone is deployed.
    event AccountCreated(address indexed owner, address indexed account, uint256 subId);

    constructor(address accountImplementation_, address manager_) {
        accountImplementation = accountImplementation_;
        manager = manager_;
    }

    /// @notice The deterministic address of an owner's account for a given subId, whether or not it
    ///         has been deployed.
    function accountOf(address owner, uint256 subId) public view returns (address) {
        return LibClone.predictDeterministicAddress(
            accountImplementation, _args(owner), _salt(owner, subId), address(this)
        );
    }

    /// @notice Deploys an owner's account for a subId if it does not yet exist, returning its
    ///         address. Idempotent: a repeat call, or a lost lazy-deploy race, returns the existing
    ///         account instead of reverting.
    function createAccount(address owner, uint256 subId) external returns (address account) {
        account = accountOf(owner, subId);
        if (account.code.length == 0) {
            LibClone.cloneDeterministic(accountImplementation, _args(owner), _salt(owner, subId));
            emit AccountCreated(owner, account, subId);
        }
    }

    /// @notice The immutable args baked into a clone: (owner, manager). The manager is this
    ///         factory's, so the owner cannot choose it.
    function _args(address owner) internal view returns (bytes memory) {
        return abi.encode(owner, manager);
    }

    /// @notice The CREATE2 salt, binding owner, manager, and subId so addresses are distinct per
    ///         owner, per router version, and per sub-account. Binding owner also neutralizes
    ///         address squatting: deploying at someone's predicted address bakes them in as owner.
    function _salt(address owner, uint256 subId) internal view returns (bytes32) {
        return keccak256(abi.encode(owner, manager, subId));
    }
}
