// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {BalanceDelta} from "@uniswap/v4-core/contracts/types/BalanceDelta.sol";
import "./IPeripheryImmutableState.sol";
import {IPoolManager} from "@uniswap/v4-core/contracts/interfaces/IPoolManager.sol";

interface INonfungiblePositionManager is IERC721, IPeripheryImmutableState {
    struct MintParams {
        IPoolManager.PoolKey poolKey;
        int24 tickLower;
        int24 tickUpper;
        uint256 amount0Desired;
        uint256 amount1Desired;
        uint256 amount0Min;
        uint256 amount1Min;
        address recipient;
        uint256 deadline;
    }

    /// @notice Creates a new position wrapped in a NFT
    /// @param params The params necessary to mint a position, encoded as `MintParams` in calldata
    /// @return delta The amount of token1
    function mint(MintParams calldata params) external payable returns (BalanceDelta delta);
}
