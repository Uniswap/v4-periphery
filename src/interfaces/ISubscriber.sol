// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";

/// @notice Interface that a Subscriber contract should implement to receive updates from the v4 position manager
interface ISubscriber {
    /// @notice Called when a position subscribes to this subscriber contract
    /// @param tokenId the token ID of the position
    /// @param data additional data passed in by the caller
    function notifySubscribe(uint256 tokenId, bytes memory data) external;
    
    /// @notice Called when a position unsubscribes from the subscriber
    /// @dev This call's gas is capped at `unsubscribeGasLimit` (set at deployment)
    /// @dev Because of EIP-150, solidity may only allocate 63/64 of gasleft()
    /// @param tokenId the token ID of the position
    function notifyUnsubscribe(uint256 tokenId) external;
    
    /// @notice Called when a position modifies its liquidity or collects fees
    /// @param tokenId the token ID of the position
    /// @param liquidityChange the change in liquidity on the underlying position
    /// @param feesAccrued the fees to be collected from the position as a result of the modifyLiquidity call
    /// @dev Note that feesAccrued can be artificially inflated by a malicious user
    /// An actor can inflate feeGrowthGlobal (and consequently feesAccrued) by atomically donating and collecting the fees within the same unlockCallback
    function notifyModifyLiquidity(uint256 tokenId, int256 liquidityChange, BalanceDelta feesAccrued) external;
    
    /// @notice Called when a position transfers ownership
    /// @param tokenId the token ID of the position
    /// @param previousOwner address of the old owner
    /// @param newOwner address of the new owner
    function notifyTransfer(uint256 tokenId, address previousOwner, address newOwner) external;
}
