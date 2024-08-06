// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {PositionConfig} from "../libraries/PositionConfig.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";

/// @notice Interface that a Subscriber contract should implement to receive updates from the v4 position manager
interface ISubscriber {
    /// @param tokenId the token ID of the position
    /// @param config details about the position
    /// @param data additional data passed in by the caller
    function notifySubscribe(uint256 tokenId, PositionConfig memory config, bytes memory data) external;
    /// @param tokenId the token ID of the position
    /// @param config details about the position
    /// @param data additional data passed in by the caller
    function notifyUnsubscribe(uint256 tokenId, PositionConfig memory config, bytes memory data) external;
    /// @param tokenId the token ID of the position
    /// @param config details about the position
    /// @param liquidityChange the change in liquidity on the underlying position
    /// @param feesAccrued the fees to be collected from the position as a result of the modifyLiquidity call
    function notifyModifyLiquidity(
        uint256 tokenId,
        PositionConfig memory config,
        int256 liquidityChange,
        BalanceDelta feesAccrued
    ) external;
    /// @param tokenId the token ID of the position
    /// @param previousOwner address of the old owner
    /// @param newOwner address of the new owner
    function notifyTransfer(uint256 tokenId, address previousOwner, address newOwner) external;
}
