// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {CommonBase} from "forge-std/Base.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";

import {IPositionManager} from "../../src/interfaces/IPositionManager.sol";
import {Actions} from "../../src/libraries/Actions.sol";
import {PositionConfig} from "./PositionConfig.sol";
import {Planner, Plan} from "../shared/Planner.sol";
import {HookSavesDelta} from "./HookSavesDelta.sol";

abstract contract LiquidityOperations is CommonBase {
    using SafeCast for *;

    IPositionManager lpm;

    uint256 _deadline = block.timestamp + 1;

    uint128 constant MAX_SLIPPAGE_INCREASE = type(uint128).max;
    uint128 constant MIN_SLIPPAGE_DECREASE = 0 wei;

    function mint(PositionConfig memory config, uint256 liquidity, address recipient, bytes memory hookData) internal {
        bytes memory calls = getMintEncoded(config, liquidity, recipient, hookData);
        lpm.modifyLiquidities(calls, _deadline);
    }

    function mintWithNative(
        uint160 sqrtPriceX96,
        PositionConfig memory config,
        uint256 liquidity,
        address recipient,
        bytes memory hookData
    ) internal {
        // determine the amount of ETH to send on-mint
        (uint256 amount0,) = LiquidityAmounts.getAmountsForLiquidity(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(config.tickLower),
            TickMath.getSqrtPriceAtTick(config.tickUpper),
            liquidity.toUint128()
        );
        bytes memory calls = getMintEncoded(config, liquidity, recipient, hookData);
        // add extra wei because modifyLiquidities may be rounding up, LiquidityAmounts is imprecise?
        lpm.modifyLiquidities{value: amount0 + 1}(calls, _deadline);
    }

    function increaseLiquidity(
        uint256 tokenId,
        PositionConfig memory config,
        uint256 liquidityToAdd,
        bytes memory hookData
    ) internal {
        bytes memory calls = getIncreaseEncoded(tokenId, config, liquidityToAdd, hookData);
        lpm.modifyLiquidities(calls, _deadline);
    }

    // do not make external call before unlockAndExecute, allows us to test reverts
    function decreaseLiquidity(
        uint256 tokenId,
        PositionConfig memory config,
        uint256 liquidityToRemove,
        bytes memory hookData
    ) internal {
        bytes memory calls = getDecreaseEncoded(tokenId, config, liquidityToRemove, hookData);
        lpm.modifyLiquidities(calls, _deadline);
    }

    function collect(uint256 tokenId, PositionConfig memory config, bytes memory hookData) internal {
        bytes memory calls = getCollectEncoded(tokenId, config, hookData);
        lpm.modifyLiquidities(calls, _deadline);
    }

    // This is encoded with close calls. Not all burns need to be encoded with closes if there is no liquidity in the position.
    function burn(uint256 tokenId, PositionConfig memory config, bytes memory hookData) internal {
        bytes memory calls = getBurnEncoded(tokenId, config, hookData);
        lpm.modifyLiquidities(calls, _deadline);
    }

    // Helper functions for getting encoded calldata for .modifyLiquidities() or .modifyLiquiditiesWithoutUnlock()
    function getMintEncoded(PositionConfig memory config, uint256 liquidity, address recipient, bytes memory hookData)
        internal
        pure
        returns (bytes memory)
    {
        return getMintEncoded(config, liquidity, MAX_SLIPPAGE_INCREASE, MAX_SLIPPAGE_INCREASE, recipient, hookData);
    }

    function getMintEncoded(
        PositionConfig memory config,
        uint256 liquidity,
        uint128 amount0Max,
        uint128 amount1Max,
        address recipient,
        bytes memory hookData
    ) internal pure returns (bytes memory) {
        Plan memory planner = Planner.init();
        planner.add(
            Actions.MINT_POSITION,
            abi.encode(
                config.poolKey,
                config.tickLower,
                config.tickUpper,
                liquidity,
                amount0Max,
                amount1Max,
                recipient,
                hookData
            )
        );

        return planner.finalizeModifyLiquidityWithClose(config.poolKey);
    }

    function getIncreaseEncoded(
        uint256 tokenId,
        PositionConfig memory config,
        uint256 liquidityToAdd,
        bytes memory hookData
    ) internal pure returns (bytes memory) {
        // max slippage
        return
            getIncreaseEncoded(tokenId, config, liquidityToAdd, MAX_SLIPPAGE_INCREASE, MAX_SLIPPAGE_INCREASE, hookData);
    }

    function getIncreaseEncoded(
        uint256 tokenId,
        PositionConfig memory config,
        uint256 liquidityToAdd,
        uint128 amount0Max,
        uint128 amount1Max,
        bytes memory hookData
    ) internal pure returns (bytes memory) {
        Plan memory planner = Planner.init();
        planner.add(Actions.INCREASE_LIQUIDITY, abi.encode(tokenId, liquidityToAdd, amount0Max, amount1Max, hookData));
        return planner.finalizeModifyLiquidityWithClose(config.poolKey);
    }

    function getDecreaseEncoded(
        uint256 tokenId,
        PositionConfig memory config,
        uint256 liquidityToRemove,
        bytes memory hookData
    ) internal pure returns (bytes memory) {
        return getDecreaseEncoded(
            tokenId, config, liquidityToRemove, MIN_SLIPPAGE_DECREASE, MIN_SLIPPAGE_DECREASE, hookData
        );
    }

    function getDecreaseEncoded(
        uint256 tokenId,
        PositionConfig memory config,
        uint256 liquidityToRemove,
        uint128 amount0Min,
        uint128 amount1Min,
        bytes memory hookData
    ) internal pure returns (bytes memory) {
        Plan memory planner = Planner.init();
        planner.add(
            Actions.DECREASE_LIQUIDITY, abi.encode(tokenId, liquidityToRemove, amount0Min, amount1Min, hookData)
        );
        return planner.finalizeModifyLiquidityWithClose(config.poolKey);
    }

    function getCollectEncoded(uint256 tokenId, PositionConfig memory config, bytes memory hookData)
        internal
        pure
        returns (bytes memory)
    {
        return getCollectEncoded(tokenId, config, MIN_SLIPPAGE_DECREASE, MIN_SLIPPAGE_DECREASE, hookData);
    }

    function getCollectEncoded(
        uint256 tokenId,
        PositionConfig memory config,
        uint128 amount0Min,
        uint128 amount1Min,
        bytes memory hookData
    ) internal pure returns (bytes memory) {
        Plan memory planner = Planner.init();
        planner.add(Actions.DECREASE_LIQUIDITY, abi.encode(tokenId, 0, amount0Min, amount1Min, hookData));
        return planner.finalizeModifyLiquidityWithClose(config.poolKey);
    }

    function getBurnEncoded(uint256 tokenId, PositionConfig memory config, bytes memory hookData)
        internal
        pure
        returns (bytes memory)
    {
        return getBurnEncoded(tokenId, config, MIN_SLIPPAGE_DECREASE, MIN_SLIPPAGE_DECREASE, hookData);
    }

    function getBurnEncoded(
        uint256 tokenId,
        PositionConfig memory config,
        uint128 amount0Min,
        uint128 amount1Min,
        bytes memory hookData
    ) internal pure returns (bytes memory) {
        Plan memory planner = Planner.init();
        planner.add(Actions.BURN_POSITION, abi.encode(tokenId, amount0Min, amount1Min, hookData));
        // Close needed on burn in case there is liquidity left in the position.
        return planner.finalizeModifyLiquidityWithClose(config.poolKey);
    }
}
