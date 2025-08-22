// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {V2OnV4Pair} from "./V2OnV4Pair.sol";
import {
    toBeforeSwapDelta, BeforeSwapDelta, BeforeSwapDeltaLibrary
} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {IUniswapV2Factory} from "briefcase/protocols/v2-core/interfaces/IUniswapV2Factory.sol";
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
import {BaseHook} from "../../utils/BaseHook.sol";

/// @title Uniswap V2 on Uniswap V4 as a hook
contract V2OnV4FactoryHook is BaseHook, V2OnV4PairDeployer, IUniswapV2Factory {
    using CurrencyLibrary for Currency;
    using SafeCast for int256;
    using SafeCast for uint256;

    address public feeTo;
    address public immutable feeToSetter;
    uint24 public constant SWAP_FEE = 3000;
    int24 public constant TICK_SPACING = 1;

    mapping(address => mapping(address => address)) public getPair;
    address[] public allPairs;

    error InvalidFee();
    error LiquidityNotAllowed();
    error InvalidTickSpacing();
    error InvalidToken();
    error IdenticalAddresses();
    error ZeroAddress();
    error PairExists();
    error Forbidden();
    error FeeToSetterLocked();

    constructor(IPoolManager _manager) BaseHook(_manager) {
        feeToSetter = address(_manager.protocolFeeController());
    }

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

    function allPairsLength() external view returns (uint256) {
        return allPairs.length;
    }

    function createPair(address tokenA, address tokenB) public returns (address pair) {
        require(tokenA != tokenB, IdenticalAddresses());
        (address token0, address token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        require(token0 != address(0), ZeroAddress());
        require(getPair[token0][token1] == address(0), PairExists()); // single check is sufficient
        deploy(token0, token1, address(poolManager));
        getPair[token0][token1] = pair;
        getPair[token1][token0] = pair; // populate mapping in the reverse direction
        allPairs.push(pair);
        emit PairCreated(token0, token1, pair, allPairs.length);
    }

    function setFeeToSetter(address) external pure {
        revert FeeToSetterLocked();
    }

    function setFeeTo(address _feeTo) external {
        require(msg.sender == feeToSetter, Forbidden());
        feeTo = _feeTo;
    }

    /// @notice Validates pool initialization parameters
    /// @dev Ensures pool contains wrapper and underlying tokens with zero fee
    /// @param poolKey The pool configuration including tokens and fee
    /// @return The function selector if validation passes
    function _beforeInitialize(address, PoolKey calldata poolKey, uint160) internal override returns (bytes4) {
        require(poolKey.fee == SWAP_FEE, InvalidFee());
        require(poolKey.tickSpacing == TICK_SPACING, InvalidTickSpacing());

        if (getPair[Currency.unwrap(poolKey.currency0)][Currency.unwrap(poolKey.currency1)] == address(0)) {
            // pair doesn't exist, create it
            createPair(Currency.unwrap(poolKey.currency0), Currency.unwrap(poolKey.currency1));
        }

        return IHooks.beforeInitialize.selector;
    }

    /// @notice Prevents liquidity operations on wrapper pools
    /// @dev Always reverts as liquidity is managed through the token wrapper
    function _beforeAddLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        internal
        pure
        override
        returns (bytes4)
    {
        revert LiquidityNotAllowed();
    }

    function _beforeSwap(address, PoolKey calldata poolKey, SwapParams calldata params, bytes calldata)
        internal
        override
        returns (bytes4, BeforeSwapDelta swapDelta, uint24)
    {
        V2OnV4Pair pair = V2OnV4Pair(getPair[Currency.unwrap(poolKey.currency0)][Currency.unwrap(poolKey.currency1)]);

        (Currency tokenIn, Currency tokenOut) =
            params.zeroForOne ? (poolKey.currency0, poolKey.currency1) : (poolKey.currency1, poolKey.currency0);
        (uint112 reserve0, uint112 reserve1,) = pair.getReserves();
        (uint256 reserveIn, uint256 reserveOut) = tokenIn == poolKey.currency0
            ? (uint256(reserve0), uint256(reserve1))
            : (uint256(reserve1), uint256(reserve0));
        uint256 amountSpecified =
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
        pair.swap(amount0Out, amount1Out, address(this), new bytes(0));
        poolManager.burn(address(this), tokenOut.toId(), amountOut);

        return (IHooks.beforeSwap.selector, swapDelta, 0);
    }
}
