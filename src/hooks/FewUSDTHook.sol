// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "solmate/src/utils/ReentrancyGuard.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import {BaseHook} from "../utils/BaseHook.sol";
import {DeltaResolver} from "../base/DeltaResolver.sol";
import {IFewWrappedToken} from "../interfaces/external/IFewWrappedToken.sol";

/// @title Wrapped Few USDT Token Hook
/// @notice Hook for wrapping/unwrapping fewUSDT tokens in Uniswap V4 pools
/// @dev Implements 1:1 wrapping/unwrapping between USDT and fewUSDT
/// @dev Special implementation for USDT which doesn't return bool from approve function
/// @dev Includes reentrancy protection and comprehensive input validation
contract FewUSDTHook is BaseHook, DeltaResolver, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using CurrencyLibrary for Currency;
    using SafeCast for int256;
    using SafeCast for uint256;
    
    /// @notice Custom errors for better gas efficiency and clarity
    error WrapFailed();
    error UnwrapFailed();
    error InvalidAddress();
    
    /// @notice The fewUSDT contract used for wrapping/unwrapping operations
    IFewWrappedToken public immutable fewUSDT;

    /// @notice The wrapped token currency (fewUSDT)
    Currency public immutable wrapperCurrency;
    /// @notice The underlying token currency (USDT)
    Currency public immutable underlyingCurrency;
    /// @notice Indicates whether wrapping occurs when swapping from token0 to token1
    bool public immutable wrapZeroForOne;

    /// @notice Creates a new fewUSDT wrapper hook
    /// @param _manager The Uniswap V4 pool manager
    /// @param _fewUSDT The fewUSDT contract address
    /// @dev Initializes with fewUSDT as wrapper token and USDT as underlying token
    /// @dev Uses SafeERC20.forceApprove to handle USDT's non-standard approve function
    /// @dev Includes comprehensive input validation for security
    constructor(IPoolManager _manager, IFewWrappedToken _fewUSDT)
        BaseHook(_manager)
    {
        // Input validation
        if (address(_manager) == address(0)) revert InvalidAddress();
        if (address(_fewUSDT) == address(0)) revert InvalidAddress();
        
        fewUSDT = _fewUSDT;
        wrapperCurrency = Currency.wrap(address(_fewUSDT));
        underlyingCurrency = Currency.wrap(_fewUSDT.token());
        wrapZeroForOne = underlyingCurrency < wrapperCurrency;
        
        // SafeERC20.forceApprove for USDT compatibility
        IERC20(Currency.unwrap(underlyingCurrency)).forceApprove(address(fewUSDT), type(uint256).max);
    }

    /// @notice Returns hook permissions
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

    /// @notice Validates pool initialization parameters
    /// @dev Ensures pool contains only wrapper and underlying tokens with zero fee
    /// @param poolKey The pool configuration including tokens and fee
    /// @return The function selector if validation passes
    function _beforeInitialize(address, PoolKey calldata poolKey, uint160) internal view override returns (bytes4) {
        // Ensure pool tokens are the wrapper currency and underlying currency
        bool isValidPair = wrapZeroForOne
            ? (poolKey.currency0 == underlyingCurrency && poolKey.currency1 == wrapperCurrency)
            : (poolKey.currency0 == wrapperCurrency && poolKey.currency1 == underlyingCurrency);

        if (!isValidPair) revert("InvalidPoolToken");
        if (poolKey.fee != 0) revert("InvalidPoolFee");

        return IHooks.beforeInitialize.selector;
    }

    /// @notice Allow liquidity operations
    function _beforeAddLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        bytes calldata
    ) internal pure override returns (bytes4) {
        return IHooks.beforeAddLiquidity.selector;
    }

    /// @notice Handles token wrapping and unwrapping during swaps
    function _beforeSwap(address, PoolKey calldata, SwapParams calldata params, bytes calldata)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        bool isExactInput = params.amountSpecified < 0;

        if (wrapZeroForOne == params.zeroForOne) {
            // we are wrapping
            uint256 inputAmount =
                isExactInput ? uint256(-params.amountSpecified) : _getWrapInputRequired(uint256(params.amountSpecified));
            _take(underlyingCurrency, address(this), inputAmount);
            uint256 wrappedAmount = _deposit(inputAmount);
            _settle(wrapperCurrency, address(this), wrappedAmount);
            int128 amountUnspecified =
                isExactInput ? -wrappedAmount.toInt256().toInt128() : inputAmount.toInt256().toInt128();
            BeforeSwapDelta swapDelta = toBeforeSwapDelta(-params.amountSpecified.toInt128(), amountUnspecified);
            return (IHooks.beforeSwap.selector, swapDelta, 0);
        } else {
            // we are unwrapping
            uint256 inputAmount = isExactInput
                ? uint256(-params.amountSpecified)
                : _getUnwrapInputRequired(uint256(params.amountSpecified));
            _take(wrapperCurrency, address(this), inputAmount);
            uint256 unwrappedAmount = _withdraw(inputAmount);
            _settle(underlyingCurrency, address(this), unwrappedAmount);
            int128 amountUnspecified =
                isExactInput ? -unwrappedAmount.toInt256().toInt128() : inputAmount.toInt256().toInt128();
            BeforeSwapDelta swapDelta = toBeforeSwapDelta(-params.amountSpecified.toInt128(), amountUnspecified);
            return (IHooks.beforeSwap.selector, swapDelta, 0);
        }
    }

    /// @notice Transfers tokens to the pool manager
    function _pay(Currency token, address, uint256 amount) internal override {
        token.transfer(address(poolManager), amount);
    }

    /// @notice Wraps USDT to fewUSDT
    /// @dev Includes balance check and reentrancy protection
    /// @param underlyingAmount Amount of USDT to wrap
    /// @return Amount of fewUSDT received
    function _deposit(uint256 underlyingAmount) internal nonReentrant returns (uint256) {
        // Check if contract has sufficient USDT balance
        uint256 balance = IERC20(Currency.unwrap(underlyingCurrency)).balanceOf(address(this));
        if (balance < underlyingAmount) revert InsufficientBalance();
        
        uint256 wrappedAmount = fewUSDT.wrap(underlyingAmount);
        if (wrappedAmount == 0) revert WrapFailed();
        
        return wrappedAmount;
    }

    /// @notice Unwraps fewUSDT to USDT
    /// @dev Includes balance check and reentrancy protection
    /// @param wrapperAmount Amount of fewUSDT to unwrap
    /// @return Amount of USDT received
    function _withdraw(uint256 wrapperAmount) internal nonReentrant returns (uint256) {
        // Check if contract has sufficient fewUSDT balance
        uint256 balance = IERC20(Currency.unwrap(wrapperCurrency)).balanceOf(address(this));
        if (balance < wrapperAmount) revert InsufficientBalance();
        
        uint256 unwrappedAmount = fewUSDT.unwrap(wrapperAmount);
        if (unwrappedAmount == 0) revert UnwrapFailed();
        
        return unwrappedAmount;
    }

    /// @notice Calculates underlying tokens needed to receive desired wrapper tokens
    function _getWrapInputRequired(uint256 wrappedAmount) internal pure returns (uint256) {
        return wrappedAmount;
    }

    /// @notice Calculates wrapper tokens needed to receive desired underlying tokens
    function _getUnwrapInputRequired(uint256 underlyingAmount) internal pure returns (uint256) {
        return underlyingAmount;
    }
}
