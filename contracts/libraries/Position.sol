// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.8.20;

import {IBaseLiquidityManagement} from "../interfaces/IBaseLiquidityManagement.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";

// Updates Position storage
library PositionLibrary {
    error InsufficientLiquidity();

    // TODO ensure this is one sstore.
    function addTokensOwed(IBaseLiquidityManagement.Position storage position, BalanceDelta tokensOwed) internal {
        position.tokensOwed0 += uint128(tokensOwed.amount0());
        position.tokensOwed1 += uint128(tokensOwed.amount1());
    }

    function addLiquidity(IBaseLiquidityManagement.Position storage position, uint256 liquidity) internal {
        unchecked {
            position.liquidity += liquidity;
        }
    }

    function subtractLiquidity(IBaseLiquidityManagement.Position storage position, uint256 liquidity) internal {
        if (position.liquidity < liquidity) revert InsufficientLiquidity();
        unchecked {
            position.liquidity -= liquidity;
        }
    }

    // TODO ensure this is one sstore.
    function updateFeeGrowthInside(
        IBaseLiquidityManagement.Position storage position,
        uint256 feeGrowthInside0X128,
        uint256 feeGrowthInside1X128
    ) internal {
        position.feeGrowthInside0LastX128 = feeGrowthInside0X128;
        position.feeGrowthInside1LastX128 = feeGrowthInside1X128;
    }
}
