// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {CommonBase} from "forge-std/Base.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";

import {PositionManager, Actions} from "../../src/PositionManager.sol";
import {PositionConfig} from "../../src/libraries/PositionConfig.sol";
import {Planner} from "../shared/Planner.sol";

abstract contract LiquidityOperations is CommonBase {
    using Planner for Planner.Plan;
    using SafeCast for *;

    PositionManager lpm;

    uint256 _deadline = block.timestamp + 1;

    function mint(PositionConfig memory config, uint256 liquidity, address recipient, bytes memory hookData)
        internal
        returns (BalanceDelta)
    {
        bytes memory calls = getMintEncoded(config, liquidity, recipient, hookData);
        bytes[] memory result = lpm.modifyLiquidities(calls, _deadline);
        return abi.decode(result[0], (BalanceDelta));
    }

    function mintWithNative(
        uint160 sqrtPriceX96,
        PositionConfig memory config,
        uint256 liquidity,
        address recipient,
        bytes memory hookData
    ) internal returns (BalanceDelta) {
        // determine the amount of ETH to send on-mint
        (uint256 amount0,) = LiquidityAmounts.getAmountsForLiquidity(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(config.tickLower),
            TickMath.getSqrtPriceAtTick(config.tickUpper),
            liquidity.toUint128()
        );
        bytes memory calls = getMintEncoded(config, liquidity, recipient, hookData);
        // add extra wei because modifyLiquidities may be rounding up, LiquidityAmounts is imprecise?
        bytes[] memory result = lpm.modifyLiquidities{value: amount0 + 1}(calls, _deadline);

        return abi.decode(result[0], (BalanceDelta));
    }

    function increaseLiquidity(
        uint256 tokenId,
        PositionConfig memory config,
        uint256 liquidityToAdd,
        bytes memory hookData
    ) internal returns (BalanceDelta) {
        bytes memory calls = getIncreaseEncoded(tokenId, config, liquidityToAdd, hookData);
        bytes[] memory result = lpm.modifyLiquidities(calls, _deadline);
        return abi.decode(result[0], (BalanceDelta));
    }

    // do not make external call before unlockAndExecute, allows us to test reverts
    function decreaseLiquidity(
        uint256 tokenId,
        PositionConfig memory config,
        uint256 liquidityToRemove,
        bytes memory hookData
    ) internal returns (BalanceDelta) {
        bytes memory calls = getDecreaseEncoded(tokenId, config, liquidityToRemove, hookData);
        bytes[] memory result = lpm.modifyLiquidities(calls, _deadline);
        return abi.decode(result[0], (BalanceDelta));
    }

    function collect(uint256 tokenId, PositionConfig memory config, bytes memory hookData)
        internal
        returns (BalanceDelta)
    {
        bytes memory calls = getCollectEncoded(tokenId, config, hookData);
        bytes[] memory result = lpm.modifyLiquidities(calls, _deadline);
        return abi.decode(result[0], (BalanceDelta));
    }

    // This is encoded with close calls. Not all burns need to be encoded with closes if there is no liquidity in the position.
    function burn(uint256 tokenId, PositionConfig memory config, bytes memory hookData)
        internal
        returns (BalanceDelta)
    {
        bytes memory calls = getBurnEncoded(tokenId, config, hookData);
        bytes[] memory result = lpm.modifyLiquidities(calls, _deadline);
        return abi.decode(result[0], (BalanceDelta));
    }

    // Helper functions for getting encoded calldata for .modifyLiquidities
    function getMintEncoded(PositionConfig memory config, uint256 liquidity, address recipient, bytes memory hookData)
        internal
        pure
        returns (bytes memory)
    {
        Planner.Plan memory planner = Planner.init();
        planner = planner.add(Actions.MINT, abi.encode(config, liquidity, recipient, hookData));

        return planner.finalize(config.poolKey);
    }

    function getIncreaseEncoded(
        uint256 tokenId,
        PositionConfig memory config,
        uint256 liquidityToAdd,
        bytes memory hookData
    ) internal pure returns (bytes memory) {
        Planner.Plan memory planner = Planner.init();
        planner = planner.add(Actions.INCREASE, abi.encode(tokenId, config, liquidityToAdd, hookData));
        return planner.finalize(config.poolKey);
    }

    function getDecreaseEncoded(
        uint256 tokenId,
        PositionConfig memory config,
        uint256 liquidityToRemove,
        bytes memory hookData
    ) internal pure returns (bytes memory) {
        Planner.Plan memory planner = Planner.init();
        planner = planner.add(Actions.DECREASE, abi.encode(tokenId, config, liquidityToRemove, hookData));
        return planner.finalize(config.poolKey);
    }

    function getCollectEncoded(uint256 tokenId, PositionConfig memory config, bytes memory hookData)
        internal
        pure
        returns (bytes memory)
    {
        Planner.Plan memory planner = Planner.init();
        planner = planner.add(Actions.DECREASE, abi.encode(tokenId, config, 0, hookData));
        return planner.finalize(config.poolKey);
    }

    function getBurnEncoded(uint256 tokenId, PositionConfig memory config, bytes memory hookData)
        internal
        pure
        returns (bytes memory)
    {
        Planner.Plan memory planner = Planner.init();
        planner = planner.add(Actions.BURN, abi.encode(tokenId, config, hookData));
        // Close needed on burn in case there is liquidity left in the position.
        return planner.finalize(config.poolKey);
    }
}
