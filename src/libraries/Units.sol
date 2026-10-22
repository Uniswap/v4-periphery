// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title Units
/// @author Uniswap Labs
/// @notice The fixed-point scales the margin suite converts between. `WAD` is the scale of `Ltv` and
///         of every health factor the suite reports; `BPS` is the basis-point scale Aave reports risk
///         parameters in; `RAY` is the scale Aave v4 reports debt value in.
library Units {
    uint256 internal constant WAD = 1e18;
    uint256 internal constant BPS = 1e4;
    uint256 internal constant RAY = 1e27;
}
