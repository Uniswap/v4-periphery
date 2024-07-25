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
import {LiquidityRange} from "../../src/types/LiquidityRange.sol";
import {Planner} from "../shared/Planner.sol";

abstract contract LiquidityOperations is CommonBase {
    using Planner for Planner.Plan;
    using SafeCast for *;

    PositionManager lpm;

    uint256 _deadline = block.timestamp + 1;

    function mint(LiquidityRange memory _range, uint256 liquidity, address recipient, bytes memory hookData)
        internal
        returns (BalanceDelta)
    {
        bytes memory calls = getMintEncoded(_range, liquidity, recipient, hookData);
        bytes[] memory result = lpm.modifyLiquidities(calls, _deadline);
        return abi.decode(result[0], (BalanceDelta));
    }

    function mintWithNative(
        uint160 sqrtPriceX96,
        LiquidityRange memory _range,
        uint256 liquidity,
        address recipient,
        bytes memory hookData
    ) internal returns (BalanceDelta) {
        // determine the amount of ETH to send on-mint
        (uint256 amount0,) = LiquidityAmounts.getAmountsForLiquidity(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(_range.tickLower),
            TickMath.getSqrtPriceAtTick(_range.tickUpper),
            liquidity.toUint128()
        );
        bytes memory calls = getMintEncoded(_range, liquidity, recipient, hookData);
        // add extra wei because modifyLiquidities may be rounding up, LiquidityAmounts is imprecise?
        bytes[] memory result = lpm.modifyLiquidities{value: amount0 + 1}(calls, _deadline);

        return abi.decode(result[0], (BalanceDelta));
    }

    function increaseLiquidity(uint256 tokenId, uint256 liquidityToAdd, bytes memory hookData)
        internal
        returns (BalanceDelta)
    {
        bytes memory calls = getIncreaseEncoded(tokenId, liquidityToAdd, hookData);
        bytes[] memory result = lpm.modifyLiquidities(calls, _deadline);
        return abi.decode(result[0], (BalanceDelta));
    }

    // do not make external call before unlockAndExecute, allows us to test reverts
    function decreaseLiquidity(uint256 tokenId, uint256 liquidityToRemove, bytes memory hookData)
        internal
        returns (BalanceDelta)
    {
        bytes memory calls = getDecreaseEncoded(tokenId, liquidityToRemove, hookData);
        bytes[] memory result = lpm.modifyLiquidities(calls, _deadline);
        return abi.decode(result[0], (BalanceDelta));
    }

    function collect(uint256 tokenId, bytes memory hookData) internal returns (BalanceDelta) {
        bytes memory calls = getCollectEncoded(tokenId, hookData);
        bytes[] memory result = lpm.modifyLiquidities(calls, _deadline);
        return abi.decode(result[0], (BalanceDelta));
    }

    function burn(uint256 tokenId) internal {
        Planner.Plan memory planner = Planner.init();
        planner = planner.add(Actions.BURN, abi.encode(tokenId));
        // No close needed on burn.
        bytes memory actions = planner.encode();
        lpm.modifyLiquidities(actions, _deadline);
    }

    // Helper functions for getting encoded calldata for .modifyLiquidities
    function getMintEncoded(LiquidityRange memory _range, uint256 liquidity, address recipient, bytes memory hookData)
        internal
        pure
        returns (bytes memory)
    {
        Planner.Plan memory planner = Planner.init();
        planner = planner.add(Actions.MINT, abi.encode(_range, liquidity, recipient, hookData));

        return planner.finalize(_range.poolKey);
    }

    function getIncreaseEncoded(uint256 tokenId, uint256 liquidityToAdd, bytes memory hookData)
        internal
        view
        returns (bytes memory)
    {
        (PoolKey memory key,,) = lpm.tokenRange(tokenId);
        Planner.Plan memory planner = Planner.init();
        planner = planner.add(Actions.INCREASE, abi.encode(tokenId, liquidityToAdd, hookData));
        return planner.finalize(key);
    }

    function getDecreaseEncoded(uint256 tokenId, uint256 liquidityToRemove, bytes memory hookData)
        internal
        view
        returns (bytes memory)
    {
        (PoolKey memory key,,) = lpm.tokenRange(tokenId);
        Planner.Plan memory planner = Planner.init();
        planner = planner.add(Actions.DECREASE, abi.encode(tokenId, liquidityToRemove, hookData));
        return planner.finalize(key);
    }

    function getCollectEncoded(uint256 tokenId, bytes memory hookData) internal view returns (bytes memory) {
        (PoolKey memory poolKey,,) = lpm.tokenRange(tokenId);
        Planner.Plan memory planner = Planner.init();
        planner = planner.add(Actions.DECREASE, abi.encode(tokenId, 0, hookData));
        return planner.finalize(poolKey);
    }
}
