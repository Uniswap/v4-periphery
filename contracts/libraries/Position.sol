// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.8.20;

import {IBaseLiquidityManagement} from "../interfaces/IBaseLiquidityManagement.sol";

// Updates Position storage
library PositionLibrary {
    // TODO ensure this is one sstore.
    function updateTokensOwed(
        IBaseLiquidityManagement.Position storage position,
        uint128 tokensOwed0,
        uint128 tokensOwed1
    ) internal {
        position.tokensOwed0 = tokensOwed0;
        position.tokensOwed1 = tokensOwed1;
    }

    function add(IBaseLiquidityManagement.Position storage position, uint256 liquidity) internal {
        unchecked {
            position.liquidity += liquidity;
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
