// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IAllowlistChecker} from "../../src/hooks/permissionedPools/interfaces/IAllowlistChecker.sol";
import {BaseAllowlistChecker} from "../../src/hooks/permissionedPools/BaseAllowListChecker.sol";

contract MockAllowList is BaseAllowlistChecker {
    // Mapping to track allowed addresses
    mapping(address => bool) public allowedAddresses;

    // Events for tracking allowlist changes
    event AddressAddedToAllowlist(address indexed account);
    event AddressRemovedFromAllowlist(address indexed account);

    constructor() BaseAllowlistChecker() {}

    /**
     * @dev Add an address to the allowlist
     * @param account The address to add to the allowlist
     */
    function addToAllowList(address account) external {
        require(account != address(0), "Cannot add zero address");
        require(!allowedAddresses[account], "Address already in allowlist");

        allowedAddresses[account] = true;
        emit AddressAddedToAllowlist(account);
    }

    /**
     * @dev Remove an address from the allowlist
     * @param account The address to remove from the allowlist
     */
    function removeFromAllowList(address account) external {
        require(allowedAddresses[account], "Address not in allowlist");

        allowedAddresses[account] = false;
        emit AddressRemovedFromAllowlist(account);
    }

    /**
     * @dev Check if an address is in the allowlist
     * @param account The address to check
     * @return True if the address is allowed, false otherwise
     */
    function checkAllowlist(address account) public view override returns (bool) {
        return allowedAddresses[account];
    }

    /**
     * @dev Check if multiple addresses are in the allowlist
     * @param accounts Array of addresses to check
     * @return Array of boolean values indicating if each address is allowed
     */
    function checkAllowlistBatch(address[] calldata accounts) external view returns (bool[] memory) {
        bool[] memory results = new bool[](accounts.length);

        for (uint256 i = 0; i < accounts.length; i++) {
            results[i] = allowedAddresses[accounts[i]];
        }

        return results;
    }

    /**
     * @dev Get the allowlist status of an address (public view function)
     * @param account The address to check
     * @return True if the address is allowed, false otherwise
     */
    function isAllowed(address account) external view returns (bool) {
        return allowedAddresses[account];
    }
}
