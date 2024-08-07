// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {PositionConfig} from "../libraries/PositionConfig.sol";
import {INotifier} from "./INotifier.sol";
import {IERC721Permit_v4} from "./IERC721Permit_v4.sol";

/// @title Position Actions Router Interface
interface IPositionActionsRouter is INotifier, IERC721Permit_v4 {
    error NotApproved(address caller);
    error IncorrectPositionConfigForTokenId(uint256 tokenId);

    event MintPosition(uint256 indexed tokenId, PositionConfig config);

    function nextTokenId() external view returns (uint256 tokenId);

    function getPositionLiquidity(uint256 tokenId, PositionConfig calldata config)
        external
        view
        returns (uint128 liquidity);
}
