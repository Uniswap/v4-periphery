// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @title CurrencyRatioSortOrder
/// @notice Provides constants for sorting currencies when displaying price ratios
/// Currencies given larger values will be in the numerator of the price ratio
/// @dev Reference: https://github.com/Uniswap/v3-periphery/blob/main/contracts/libraries/TokenRatioSortOrder.sol
library CurrencyRatioSortOrder {
    int256 constant NUMERATOR_MOST = 300;
    int256 constant NUMERATOR_MORE = 200;
    int256 constant NUMERATOR = 100;

    int256 constant DENOMINATOR_MOST = -300;
    int256 constant DENOMINATOR_MORE = -200;
    int256 constant DENOMINATOR = -100;
}
