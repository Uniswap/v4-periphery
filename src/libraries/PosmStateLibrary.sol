// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {Position} from "@uniswap/v4-core/src/libraries/Position.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";

import {PositionConfig} from "./PositionConfig.sol";

/// @notice A library for reading POSM specific information from core, wraps core's StateLibrary
library PosmStateLibrary {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    function getPositionLiquidity(IPoolManager poolManager, uint256 tokenId, PositionConfig memory config)
        internal
        view
        returns (uint128 liquidity)
    {
        bytes32 positionId =
            Position.calculatePositionKey(address(this), config.tickLower, config.tickUpper, bytes32(tokenId));
        liquidity = poolManager.getPositionLiquidity(config.poolKey.toId(), positionId);
    }
}
