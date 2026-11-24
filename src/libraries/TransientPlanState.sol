// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title TransientPlanState
/// @author Uniswap Labs
/// @notice The transient storage (EIP-1153) a margin plan carries across one PoolManager unlock: the
///         active account the account-scoped actions operate on, the amount the last
///         `ACCOUNT_REPAY` actually repaid, and the amount the last `ACCOUNT_SUPPLY_COLLATERAL`
///         supplied. Only `MarginRouter` writes any of them, never from calldata. Transient storage
///         persists for the whole transaction rather than per call, so the entry point that ran a
///         plan clears the account when it returns and resets the amounts before the plan runs.
library TransientPlanState {
    bytes32 private constant ACTIVE_ACCOUNT_SLOT = keccak256("uniswap.marginRouter.activeAccount");
    bytes32 private constant LAST_REPAID_SLOT = keccak256("uniswap.marginRouter.lastRepaid");
    bytes32 private constant LAST_SUPPLIED_SLOT = keccak256("uniswap.marginRouter.lastSupplied");

    /// @notice Binds `account` as the active account for the account-scoped actions, or clears the
    ///         binding with `address(0)`.
    /// @param account The MarginAccount to bind, or `address(0)`.
    function setActiveAccount(address account) internal {
        bytes32 slot = ACTIVE_ACCOUNT_SLOT;
        assembly ("memory-safe") {
            tstore(slot, account)
        }
    }

    /// @notice The active account, or `address(0)` when none is bound.
    /// @return account The bound MarginAccount.
    function activeAccount() internal view returns (address account) {
        bytes32 slot = ACTIVE_ACCOUNT_SLOT;
        assembly ("memory-safe") {
            account := tload(slot)
        }
    }

    /// @notice Records what the last `ACCOUNT_REPAY` actually repaid.
    /// @param repaid The measured repay amount, or zero to reset before a plan runs.
    function setLastRepaid(uint256 repaid) internal {
        bytes32 slot = LAST_REPAID_SLOT;
        assembly ("memory-safe") {
            tstore(slot, repaid)
        }
    }

    /// @notice What the last `ACCOUNT_REPAY` actually repaid, or zero if none ran since the reset.
    /// @return repaid The measured repay amount.
    function lastRepaid() internal view returns (uint256 repaid) {
        bytes32 slot = LAST_REPAID_SLOT;
        assembly ("memory-safe") {
            repaid := tload(slot)
        }
    }

    /// @notice Records what the last `ACCOUNT_SUPPLY_COLLATERAL` supplied, after resolving `OPEN_DELTA`.
    /// @param supplied The amount supplied, or zero to reset before a plan runs.
    function setLastSupplied(uint256 supplied) internal {
        bytes32 slot = LAST_SUPPLIED_SLOT;
        assembly ("memory-safe") {
            tstore(slot, supplied)
        }
    }

    /// @notice What the last `ACCOUNT_SUPPLY_COLLATERAL` supplied, or zero if none ran since the reset.
    /// @return supplied The amount supplied.
    function lastSupplied() internal view returns (uint256 supplied) {
        bytes32 slot = LAST_SUPPLIED_SLOT;
        assembly ("memory-safe") {
            supplied := tload(slot)
        }
    }
}
