// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IERC165} from "openzeppelin-contracts/contracts/utils/introspection/IERC165.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/// @title Hook statistics interface
/// @notice URC-3 interface for hook-managed reserves and immediately available liquidity
interface IHookStats is IERC165 {
    /// @notice Returns total reserves managed by the hook for a pool
    function getReserves(PoolKey calldata key) external view returns (uint256 amount0, uint256 amount1);

    /// @notice Returns hook-managed assets immediately available for swapping
    function getEffectiveLiquidity(PoolKey calldata key) external view returns (uint256 amount0, uint256 amount1);

    /// @notice Returns the hook whose statistics this contract reports
    function hook() external view returns (address);
}
