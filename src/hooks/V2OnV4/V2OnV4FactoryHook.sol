// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {
    toBeforeSwapDelta, BeforeSwapDelta, BeforeSwapDeltaLibrary
} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IUniswapV2Pair} from "briefcase/protocols/v2-core/interfaces/IUniswapV2Pair.sol";
import {WETH} from "solmate/src/tokens/WETH.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {UniswapV2Library} from "./UniswapV2Library.sol";
import {V2OnV4PairDeployer} from "./V2OnV4PairDeployer.sol";
import {IV2OnV4Pair} from "../../interfaces/IV2OnV4Pair.sol";
import {IV2OnV4Factory} from "../../interfaces/IV2OnV4Factory.sol";
import {BaseHook} from "../../utils/BaseHook.sol";

/// @title V2OnV4FactoryHook
/// @author Uniswap Labs
/// @notice Factory contract that enables Uniswap V2-style AMM pools to run on Uniswap V4 infrastructure
/// @dev Implements the IUniswapV2Factory interface while leveraging V4's hook system for pool management
contract V2OnV4FactoryHook is BaseHook, V2OnV4PairDeployer, IV2OnV4Factory {
    using CurrencyLibrary for Currency;
    using SafeCast for int256;
    using SafeCast for uint256;

    /// @notice Address that receives protocol fees when enabled
    address public feeTo;

    /// @notice Fixed swap fee of 0.3% (3000 basis points) matching V2's fee structure
    uint24 public constant override SWAP_FEE = 3000;

    /// @notice Minimum tick spacing for V4 pools (1 tick = finest granularity)
    int24 public constant override TICK_SPACING = 1;

    /// @notice Returns the address of the pair for tokenA and tokenB, if it exists
    /// @dev the first mapping is always the smaller sorted address
    mapping(address token0 => mapping(address token1 => address)) public pairs;

    /// @notice Array of all created pair addresses for enumeration
    address[] public override allPairs;

    /// @notice Deploys the V2OnV4 factory hook
    /// @param _manager The Uniswap V4 pool manager contract
    constructor(IPoolManager _manager) BaseHook(_manager) {}

    /// @inheritdoc BaseHook
    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            beforeAddLiquidity: true,
            beforeSwap: true,
            beforeSwapReturnDelta: true,
            afterSwap: false,
            afterInitialize: false,
            beforeRemoveLiquidity: false,
            afterAddLiquidity: false,
            afterRemoveLiquidity: false,
            beforeDonate: false,
            afterDonate: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    /// @notice Returns the total number of pairs created
    /// @return The length of the allPairs array
    function allPairsLength() external view override returns (uint256) {
        return allPairs.length;
    }

    /// @notice Returns the pair address for the given token addresses, or address(0) if it doesn't exist
    /// @param tokenA Address of the first token
    /// @param tokenB Address of the second token
    /// @return pair Address of the pair contract or address(0) if not found
    function getPair(address tokenA, address tokenB) external view override returns (address pair) {
        (address token0, address token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        pair = pairs[token0][token1];
    }

    /// @notice Creates a new V2-style pair for the given token addresses
    /// @param tokenA Address of the first token
    /// @param tokenB Address of the second token
    /// @return pair Address of the newly created pair contract
    /// @dev Tokens are sorted, and the pair is deployed deterministically
    function createPair(address tokenA, address tokenB) public override returns (address pair) {
        require(tokenA != tokenB, IdenticalAddresses());
        (address token0, address token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        require(token0 != address(0), ZeroAddress());
        require(pairs[token0][token1] == address(0), PairExists()); // single check is sufficient
        pair = deploy(token0, token1, address(poolManager));
        pairs[token0][token1] = pair;
        allPairs.push(pair);
        emit PairCreated(token0, token1, pair, allPairs.length);
    }

    /// @notice Returns the address authorized to set the fee recipient
    /// @return The protocol fee controller from the V4 pool manager
    /// @dev Delegates fee setter authority to V4's protocol fee controller
    function feeToSetter() public view override returns (address) {
        return poolManager.protocolFeeController();
    }

    /// @notice Prevents changing the fee setter (locked to V4's protocol controller)
    /// @dev Always reverts as fee setter is managed by V4 pool manager
    function setFeeToSetter(address) external pure override {
        revert FeeToSetterLocked();
    }

    /// @notice Sets the address that receives protocol fees
    /// @param _feeTo The address to receive protocol fees (or address(0) to disable)
    /// @dev Only callable by the current fee setter
    function setFeeTo(address _feeTo) external override {
        require(msg.sender == feeToSetter(), Forbidden());
        feeTo = _feeTo;
    }

    /// @notice Hook called before pool initialization to validate parameters and create pairs
    /// @dev Ensures the pool uses the correct fee and tick spacing, creates pair if needed
    /// @param poolKey The pool configuration including tokens, fee, and tick spacing
    /// @return The function selector indicating successful validation
    function _beforeInitialize(address, PoolKey calldata poolKey, uint160) internal override returns (bytes4) {
        require(poolKey.fee == SWAP_FEE, InvalidFee());
        require(poolKey.tickSpacing == TICK_SPACING, InvalidTickSpacing());

        if (pairs[Currency.unwrap(poolKey.currency0)][Currency.unwrap(poolKey.currency1)] == address(0)) {
            // pair doesn't exist, create it
            createPair(Currency.unwrap(poolKey.currency0), Currency.unwrap(poolKey.currency1));
        }

        return IHooks.beforeInitialize.selector;
    }

    /// @notice Hook called before adding liquidity - always reverts
    /// @dev Liquidity must be added through V2-style pair contracts, not directly to V4 pools
    /// @return Never returns, always reverts with LiquidityNotAllowed
    function _beforeAddLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        internal
        pure
        override
        returns (bytes4)
    {
        revert LiquidityNotAllowed();
    }

    /// @notice Hook called before swap execution to handle V2-style constant product swaps
    /// @dev Calculates swap amounts using V2 formula and executes through the pair contract
    /// @param poolKey The pool configuration
    /// @param params Swap parameters including direction and amount
    /// @return selector The function selector
    /// @return swapDelta The calculated swap deltas for input and output
    /// @return fee The swap fee (always 0 as fee is handled by V2 logic)
    function _beforeSwap(address, PoolKey calldata poolKey, SwapParams calldata params, bytes calldata)
        internal
        override
        returns (bytes4, BeforeSwapDelta swapDelta, uint24)
    {
        IV2OnV4Pair pair = IV2OnV4Pair(pairs[Currency.unwrap(poolKey.currency0)][Currency.unwrap(poolKey.currency1)]);

        (Currency tokenIn, Currency tokenOut, uint256 reserveIn, uint256 reserveOut, uint256 amountSpecified) =
            _parseSwap(poolKey, params, pair);
        params.amountSpecified > 0 ? uint256(params.amountSpecified) : uint256(-params.amountSpecified);

        bool isExactInput = params.amountSpecified < 0;

        uint256 amountIn;
        uint256 amountOut;
        if (isExactInput) {
            amountOut = UniswapV2Library.getAmountOut(amountSpecified, reserveIn, reserveOut);
            amountIn = uint256(-params.amountSpecified);
            swapDelta = toBeforeSwapDelta(-params.amountSpecified.toInt128(), -int128(int256(amountOut)));
        } else {
            amountIn = UniswapV2Library.getAmountIn(amountSpecified, reserveIn, reserveOut);
            amountOut = uint256(params.amountSpecified);
            swapDelta = toBeforeSwapDelta(-params.amountSpecified.toInt128(), int128(int256(amountIn)));
        }

        (uint256 amount0Out, uint256 amount1Out) = params.zeroForOne ? (uint256(0), amountOut) : (amountOut, uint256(0));
        poolManager.mint(address(pair), tokenIn.toId(), amountIn);
        pair.swapClaims(amount0Out, amount1Out, address(this), new bytes(0));
        poolManager.burn(address(this), tokenOut.toId(), amountOut);

        return (IHooks.beforeSwap.selector, swapDelta, 0);
    }

    /// @notice Parses swap parameters and retrieves reserve information
    /// @dev Helper function to extract tokens, reserves, and amounts from swap params
    /// @param poolKey The pool configuration
    /// @param params Swap parameters
    /// @param pair The V2 pair contract
    /// @return tokenIn The input token currency
    /// @return tokenOut The output token currency
    /// @return reserveIn Input token reserves
    /// @return reserveOut Output token reserves
    /// @return amountSpecified Absolute value of the specified swap amount
    function _parseSwap(PoolKey calldata poolKey, SwapParams calldata params, IV2OnV4Pair pair)
        private
        view
        returns (Currency tokenIn, Currency tokenOut, uint256 reserveIn, uint256 reserveOut, uint256 amountSpecified)
    {
        (tokenIn, tokenOut) =
            params.zeroForOne ? (poolKey.currency0, poolKey.currency1) : (poolKey.currency1, poolKey.currency0);
        (uint112 reserve0, uint112 reserve1,) = pair.getReserves();
        (reserveIn, reserveOut) = tokenIn == poolKey.currency0
            ? (uint256(reserve0), uint256(reserve1))
            : (uint256(reserve1), uint256(reserve0));
        amountSpecified =
            params.amountSpecified > 0 ? uint256(params.amountSpecified) : uint256(-params.amountSpecified);
    }
}
