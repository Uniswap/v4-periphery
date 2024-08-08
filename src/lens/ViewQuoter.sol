// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {IViewQuoter} from "../interfaces/IViewQuoter.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {QuoterMath} from "../libraries/QuoterMath.sol";

contract ViewQuoter is IViewQuoter {
    IPoolManager public immutable poolManager;

    constructor(IPoolManager _poolManager) {
        poolManager = _poolManager;
    }

    function quoteSingle(PoolKey calldata poolKey, IPoolManager.SwapParams calldata swapParams)
        public
        view
        override
        returns (int256, int256, uint160, uint32)
    {
        return QuoterMath.quote(poolManager, poolKey, swapParams);
    }
}
