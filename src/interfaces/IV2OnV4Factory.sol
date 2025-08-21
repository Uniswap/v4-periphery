// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUniswapV2Factory} from "briefcase/protocols/v2-core/interfaces/IUniswapV2Factory.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

/// @title IV2OnV4Factory
/// @notice Interface for V2-style AMM pair contracts operating on Uniswap V4 infrastructure
interface IV2OnV4Factory is IUniswapV2Factory {
    function SWAP_FEE() external pure returns (uint24);
    function TICK_SPACING() external pure returns (int24);

    error InvalidFee();
    error LiquidityNotAllowed();
    error InvalidTickSpacing();
    error InvalidToken();
    error IdenticalAddresses();
    error ZeroAddress();
    error PairExists();
    error Forbidden();
    error FeeToSetterLocked();
}
