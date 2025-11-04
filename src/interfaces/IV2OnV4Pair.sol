// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

/// @title IV2OnV4Pair
/// @notice Interface for V2-style AMM pair contracts operating on Uniswap V4 infrastructure
interface IV2OnV4Pair {
    /// @notice Minimum liquidity locked when first LP tokens are minted
    function MINIMUM_LIQUIDITY() external pure returns (uint256);

    /// @notice The Uniswap V4 pool manager contract
    function poolManager() external view returns (IPoolManager);

    /// @notice Address of the factory that deployed this pair
    function factory() external view returns (address);

    /// @notice First token in the pair
    function token0() external view returns (Currency);

    /// @notice Second token in the pair
    function token1() external view returns (Currency);

    /// @notice Cumulative price of token0 in terms of token1, used for TWAP oracles
    function price0CumulativeLast() external view returns (uint256);

    /// @notice Cumulative price of token1 in terms of token0, used for TWAP oracles
    function price1CumulativeLast() external view returns (uint256);

    /// @notice Product of reserves (k value) after last liquidity event
    function kLast() external view returns (uint256);

    /// @notice Returns the current reserves and last update timestamp
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);

    // V2 Style Functions

    /// @notice Mints liquidity tokens to the specified address
    function mint(address to) external returns (uint256 liquidity);

    /// @notice Burns liquidity tokens and returns underlying assets
    function burn(address to) external returns (uint256 amount0, uint256 amount1);

    /// @notice Executes a swap with specified output amounts
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external;

    /// @notice Transfers excess tokens to maintain balance-reserve parity
    function skim(address to) external;

    /// @notice Synchronizes reserves with current balances
    function sync() external;

    // V4 Style Claims Functions

    /// @notice Mints liquidity using V4 claims directly
    function mintClaims(address to) external returns (uint256 liquidity);

    /// @notice Burns liquidity and returns claims directly
    function burnClaims(address to) external returns (uint256 amount0, uint256 amount1);

    /// @notice Executes a swap using V4 claims directly
    function swapClaims(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external;

    /// @notice Callback executed by pool manager during unlock operations
    function unlockCallback(bytes calldata data) external returns (bytes memory);

    // Events
    event Mint(address indexed sender, uint256 amount0, uint256 amount1);
    event Burn(address indexed sender, uint256 amount0, uint256 amount1, address indexed to);
    event Swap(
        address indexed sender,
        uint256 amount0In,
        uint256 amount1In,
        uint256 amount0Out,
        uint256 amount1Out,
        address indexed to
    );
    event Sync(uint112 reserve0, uint112 reserve1);

    // Errors
    error K();
    error Forbidden();
    error NotPoolManager();
    error InvalidUnlockCallbackData();
    error InsufficientLiquidityBurned();
    error InsufficientLiquidityMinted();
    error InsufficientOutputAmount();
    error InsufficientInputAmount();
    error InsufficientLiquidity();
    error InvalidTo();
}
