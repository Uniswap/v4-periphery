// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./IPositionManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

/// @title IPositionDescriptor
/// @notice Interface for the PositionDescriptor contract
interface IPositionDescriptor {
    error InvalidTokenId(uint256 tokenId);

    /// @notice Produces the URI describing a particular token ID
    /// @dev Note this URI may be a data: URI with the JSON contents directly inlined
    /// @param positionManager The position manager for which to describe the token
    /// @param tokenId The ID of the token for which to produce a description, which may not be valid
    /// @return The URI of the ERC721-compliant metadata
    function tokenURI(IPositionManager positionManager, uint256 tokenId) external view returns (string memory);

    /// @notice Returns true if currency0 has higher priority than currency1
    /// @param currency0 The first currency address
    /// @param currency1 The second currency address
    /// @return True if currency0 has higher priority than currency1
    function flipRatio(address currency0, address currency1) external view returns (bool);

    /// @notice Returns the priority of a currency.
    /// For certain currencies on mainnet, the smaller the currency, the higher the priority
    /// And those with the higher priority values (more positive values) will be in the numerator of the price ratio
    /// @param currency The currency address
    /// @return The priority of the currency
    function currencyRatioPriority(address currency) external view returns (int256);

    /// @return The wrapped native token for this descriptor
    function wrappedNative() external view returns (address);

    /// @return The native currency label for this descriptor
    function nativeCurrencyLabel() external view returns (string memory);

    /// @return The pool manager for this descriptor
    function poolManager() external view returns (IPoolManager);
}
