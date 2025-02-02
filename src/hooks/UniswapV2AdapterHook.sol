pragma solidity ^0.8.0;

import {IUniswapV2Factory} from "@uniswap/briefcase/src/protocols/v2-core/interfaces/IUniswapV2Factory.sol";
import {IUniswapV2Pair} from "@uniswap/briefcase/src/protocols/v2-core/interfaces/IUniswapV2Pair.sol";
import {UniswapV2Library} from "@uniswap/universal-router/contracts/modules/uniswap/v2/UniswapV2Library.sol";
import {
    toBeforeSwapDelta, BeforeSwapDelta, BeforeSwapDeltaLibrary
} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {BaseHook} from "../base/hooks/BaseHook.sol";

/// @title Uniswap V2 Adapter Hook for V4
/// @notice Enables V4 users to access V2 liquidity through V4's swap interface
/// @dev This hook creates V4 pools that mirror existing V2 pairs by:
///      1. Creating V4 pools with 0.3% fee to match V2 pairs
///      2. Routing V4 swap calls through corresponding V2 pairs
///      3. Using V2's constant product math for pricing
///      4. Managing token settlement between V4 and V2
/// @dev All liquidity remains in V2 pairs - V4 pools are pass-through only
/// @dev Pools can only be created for existing V2 pairs
contract UniswapV2AdapterHook is BaseHook {
    using CurrencyLibrary for Currency;

    /// @notice Thrown when attempting to add/remove liquidity through V4
    /// @dev Liquidity operations must go through V2 pairs directly
    error LiquidityNotAllowed();

    /// @notice Thrown when pool fee doesn't match V2's 0.3% fee
    /// @dev Fees must match for proper price alignment
    error InvalidPoolFee();

    /// @notice Thrown when tick spacing doesn't match adapter's required spacing
    /// @dev Uses fixed tick spacing for V2 compatibility
    error InvalidTickSpacing();

    /// @notice Thrown when V2 pair doesn't exist for token pair
    /// @dev V2 pair must be created before V4 adapter pool
    error V2PairDoesNotExist();

    /// @notice Factory contract for looking up V2 pairs
    IUniswapV2Factory public immutable v2Factory;

    /// @notice Fee tier matching V2's 0.3% fee (30 bps)
    uint24 public constant V2_POOL_FEE = 3000;

    /// @notice Fixed tick spacing for V2 adapter pools
    /// @dev Uses minimal spacing since V2 has continuous pricing
    int24 public constant V2_TICK_SPACING = 1;
    int24 public constant V2_TICK_SPACING = 1;

    /// @notice Creates a new V2 adapter hook
    /// @param _manager V4 pool manager contract
    /// @param _v2Factory V2 factory for accessing V2 pairs
    /// @dev Hook routes V4 swaps through existing V2 pairs
    constructor(IPoolManager _manager, IUniswapV2Factory _v2Factory) BaseHook(_manager) {
        v2Factory = _v2Factory;
    }

    /// @notice Hook permissions required for V2 adapter
    /// @dev Enables swap routing and blocks liquidity operations
    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            beforeAddLiquidity: true,
            beforeRemoveLiquidity: true,
            beforeSwap: true,
            beforeSwapReturnDelta: true,
            afterSwap: false,
            afterInitialize: false,
            afterAddLiquidity: false,
            afterRemoveLiquidity: false,
            beforeDonate: false,
            afterDonate: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    /// @inheritdoc IHooks
    function beforeInitialize(address, PoolKey calldata poolKey, uint160) external view override returns (bytes4) {
        // Check that the pair exists on the v2 factory
        if (address(_getPair(poolKey)) == address(0)) revert V2PairDoesNotExist();

        if (poolKey.fee != V2_POOL_FEE) revert InvalidPoolFee();
        if (poolKey.tickSpacing != V2_TICK_SPACING) revert InvalidTickSpacing();

        return IHooks.beforeInitialize.selector;
    }

    /// @inheritdoc IHooks
    function beforeAddLiquidity(address, PoolKey calldata, IPoolManager.ModifyLiquidityParams calldata, bytes calldata)
        external
        pure
        override
        returns (bytes4)
    {
        revert LiquidityNotAllowed();
    }

    /// @inheritdoc IHooks
    function beforeRemoveLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        bytes calldata
    ) external pure override returns (bytes4) {
        revert LiquidityNotAllowed();
    }

    /// @inheritdoc IHooks
    /// @notice Routes V4 swaps through V2 pairs
    /// @dev Swap flow:
    ///      1. Finds V2 pair and gets reserves
    ///      2. Calculates amounts using V2 math
    ///      3. Takes input tokens from sender
    ///      4. Executes V2 swap
    ///      5. Settles output through pool manager
    ///      6. Returns swap delta for V4 accounting
    /// @dev Maintains V2's pricing and slippage behavior
    function beforeSwap(address, PoolKey calldata poolKey, IPoolManager.SwapParams calldata params, bytes calldata)
        external
        override
        returns (bytes4 selector, BeforeSwapDelta swapDelta, uint24 lpFeeOverride)
    {
        // Get the corresponding V2 pair and its current reserves
        IUniswapV2Pair pair = _getPair(poolKey);

        // Map V4 currencies and reserves to input/output based on swap direction
        // zeroForOne: true = token0 to token1, false = token1 to token0
        (
            Currency inputCurrency, // Token being sold
            Currency outputCurrency, // Token being bought
            uint256 inputAmount,
            uint256 amount0Out,
            uint256 amount1Out,
            int128 amountUnspecified
        ) = _getSwapDetails(pair, poolKey, params);

        // Execute the V2 swap:
        // Take input tokens from sender and send to V2 pair
        poolManager.take(inputCurrency, address(pair), inputAmount);

        // Swap on v2 and settle output tokens on PoolManager
        poolManager.sync(outputCurrency);
        pair.swap(amount0Out, amount1Out, address(poolManager), new bytes(0));
        poolManager.settle();

        swapDelta = toBeforeSwapDelta(
            // Negate amount specified to cancel to 0 in PoolManager
            -int128(params.amountSpecified),
            // Amount calculated (positive for input, negative for input needed, positive for output added)
            amountUnspecified
        );

        return (IHooks.beforeSwap.selector, swapDelta, 0); // No LP fee since V2 handles fees
    }

    /// @notice Helper to get the corresponding V2 pair for a V4 pool
    /// @param poolKey The V4 pool key containing the token pair
    /// @return The V2 pair contract for these tokens
    /// @dev Unwraps V4 Currency types to addresses for V2 compatibility
    /// @dev Returns address(0) if pair doesn't exist, which is checked in beforeInitialize
    function _getPair(PoolKey memory poolKey) internal view returns (IUniswapV2Pair) {
        return IUniswapV2Pair(v2Factory.getPair(Currency.unwrap(poolKey.currency0), Currency.unwrap(poolKey.currency1)));
    }

    /// @notice Calculates all necessary swap details for routing through V2
    /// @param pair The V2 pair to execute the swap through
    /// @param poolKey The V4 pool key containing swap tokens
    /// @param params The V4 swap parameters
    /// @return inputCurrency The token being sold
    /// @return outputCurrency The token being bought
    /// @return inputAmount The amount of input tokens to take from sender
    /// @return amount0Out The amount of token0 output from V2 pair
    /// @return amount1Out The amount of token1 output from V2 pair
    /// @return amountUnspecified The calculated swap amount for V4 delta
    /// @dev Handles both exact input and exact output swaps
    /// @dev Uses V2's math to calculate amounts and maintain price alignment
    function _getSwapDetails(IUniswapV2Pair pair, PoolKey memory poolKey, IPoolManager.SwapParams memory params)
        private
        view
        returns (
            Currency inputCurrency,
            Currency outputCurrency,
            uint256 inputAmount,
            uint256 amount0Out,
            uint256 amount1Out,
            int128 amountUnspecified
        )
    {
        // Determine if this is an exact input or exact output swap
        bool isExactInput = params.amountSpecified < 0;
        (uint256 reserve0, uint256 reserve1,) = pair.getReserves();
        uint256 inputReserve;
        uint256 outputReserve;

        // Map V4 currencies and reserves to input/output based on swap direction
        // zeroForOne: true = token0 to token1, false = token1 to token0
        (
            inputCurrency, // Token being sold
            outputCurrency, // Token being bought
            inputReserve, // Reserve of input token in V2 pair
            outputReserve // Reserve of output token in V2 pair
        ) = params.zeroForOne
            ? (poolKey.currency0, poolKey.currency1, reserve0, reserve1)
            : (poolKey.currency1, poolKey.currency0, reserve1, reserve0);

        // Calculate input and output amounts using V2 math
        uint256 outputAmount;
        if (isExactInput) {
            inputAmount = uint256(-params.amountSpecified);
            outputAmount = UniswapV2Library.getAmountOut(inputAmount, inputReserve, outputReserve);
            amountUnspecified = -int128(int256(outputAmount));
        } else {
            outputAmount = uint256(params.amountSpecified);
            inputAmount = UniswapV2Library.getAmountIn(outputAmount, inputReserve, outputReserve);
            amountUnspecified = int128(int256(inputAmount));
        }

        // 2. Prepare V2 swap parameters (amount0Out, amount1Out)
        (amount0Out, amount1Out) = params.zeroForOne
            ? (uint256(0), outputAmount) // If selling token0, output is token1
            : (outputAmount, uint256(0)); // If selling token1, output is token0
    }
}
