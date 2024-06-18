// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

interface IUniswapV3Factory {
    event MiddlewareCreated(
        address implementation,
        address middleware
    );

    /// @notice Emitted when a new fee amount is enabled for middleware creation via the factory
    /// @param fee The enabled fee, denominated in hundredths of a bip
    /// @param tickSpacing The minimum number of ticks between initialized ticks for middlewares created with the given fee
    event FeeAmountEnabled(uint24 indexed fee, int24 indexed tickSpacing);

    /// @notice Returns the current owner of the factory
    /// @dev Can be changed by the current owner via setOwner
    /// @return The address of the factory owner
    function owner() external view returns (address);

    /// @notice Returns the tick spacing for a given fee amount, if enabled, or 0 if not enabled
    /// @dev A fee amount can never be removed, so this value should be hard coded or cached in the calling context
    /// @param fee The enabled fee, denominated in hundredths of a bip. Returns 0 in case of unenabled fee
    /// @return The tick spacing
    function feeAmountTickSpacing(uint24 fee) external view returns (int24);

    /// @notice Returns the middleware address for a given pair of tokens and a fee, or address 0 if it does not exist
    /// @dev tokenA and tokenB may be passed in either token0/token1 or token1/token0 order
    /// @param tokenA The contract address of either token0 or token1
    /// @param tokenB The contract address of the other token
    /// @param fee The fee collected upon every swap in the middleware, denominated in hundredths of a bip
    /// @return middleware The middleware address
    function getMiddleware(
        address tokenA,
        address tokenB,
        uint24 fee
    ) external view returns (address middleware);

    /// @notice Creates a middleware for the given two tokens and fee
    /// @param tokenA One of the two tokens in the desired middleware
    /// @param tokenB The other of the two tokens in the desired middleware
    /// @param fee The desired fee for the middleware
    /// @dev tokenA and tokenB may be passed in either order: token0/token1 or token1/token0. tickSpacing is retrieved
    /// from the fee. The call will revert if the middleware already exists, the fee is invalid, or the token arguments
    /// are invalid.
    /// @return middleware The address of the newly created middleware
    function createMiddleware(
        address tokenA,
        address tokenB,
        uint24 fee
    ) external returns (address middleware);

    /// @notice Updates the owner of the factory
    /// @dev Must be called by the current owner
    /// @param _owner The new owner of the factory
    function setOwner(address _owner) external;

    /// @notice Enables a fee amount with the given tickSpacing
    /// @dev Fee amounts may never be removed once enabled
    /// @param fee The fee amount to enable, denominated in hundredths of a bip (i.e. 1e-6)
    /// @param tickSpacing The spacing between ticks to be enforced for all middlewares created with the given fee amount
    function enableFeeAmount(uint24 fee, int24 tickSpacing) external;
}