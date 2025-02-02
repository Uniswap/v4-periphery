pragma solidity ^0.8.0;

import {
    toBeforeSwapDelta, BeforeSwapDelta, BeforeSwapDeltaLibrary
} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {BaseHook} from "./BaseHook.sol";

/// @title Base Token Wrapper Hook
/// @notice Abstract base contract for implementing token wrapper hooks in Uniswap V4
/// @dev This contract provides the base functionality for wrapping/unwrapping tokens through V4 pools
/// @dev All liquidity operations are blocked as liquidity is managed through the underlying token wrapper
/// @dev Implementing contracts must provide deposit() and withdraw() functions
abstract contract BaseTokenWrapperHook is BaseHook {
    using CurrencyLibrary for Currency;

    /// @notice Thrown when attempting to add or remove liquidity
    /// @dev Liquidity operations are blocked since all liquidity is managed by the token wrapper
    error LiquidityNotAllowed();

    /// @notice Thrown when initializing a pool with invalid tokens
    /// @dev Pool must contain exactly one wrapper token and its underlying token
    error InvalidPoolToken();

    /// @notice Thrown when initializing a pool with non-zero fee
    /// @dev Fee must be 0 as wrapper pools don't charge fees
    error InvalidPoolFee();

    /// @notice The wrapped token currency (e.g., WETH)
    Currency public immutable wrapperCurrency;

    /// @notice The underlying token currency (e.g., ETH)
    Currency public immutable underlyingCurrency;

    /// @notice Creates a new token wrapper hook
    /// @param _manager The Uniswap V4 pool manager
    /// @param _wrapper The wrapped token currency (e.g., WETH)
    /// @param _underlying The underlying token currency (e.g., ETH)
    constructor(IPoolManager _manager, Currency _wrapper, Currency _underlying) BaseHook(_manager) {
        wrapperCurrency = _wrapper;
        underlyingCurrency = _underlying;
    }

    /// @notice Returns a struct of permissions to signal which hook functions are to be implemented
    /// @dev Used at deployment to validate the address correctly represents the expected permissions
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
        // ensure pool tokens are the wrapper currency and underlying currency
        bool isValidPair = (poolKey.currency0 == wrapperCurrency && poolKey.currency1 == underlyingCurrency)
            || (poolKey.currency0 == underlyingCurrency && poolKey.currency1 == wrapperCurrency);

        if (!isValidPair) revert InvalidPoolToken();
        if (poolKey.fee != 0) revert InvalidPoolFee();

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
    /// @notice Handles the wrapping/unwrapping of tokens during a swap
    /// @dev Takes input tokens from sender, performs wrap/unwrap, and settles output tokens
    /// @dev No fees are charged on these operations
    function beforeSwap(address, PoolKey calldata poolKey, IPoolManager.SwapParams calldata params, bytes calldata)
        external
        override
        returns (bytes4 selector, BeforeSwapDelta swapDelta, uint24 lpFeeOverride)
    {
        bool isWrapping = _isWrapping(poolKey, params.zeroForOne);
        bool isExactInput = params.amountSpecified > 0;

        uint256 inputAmount = isExactInput
            ? uint256(params.amountSpecified)
            : _getInputRequired(uint256(-params.amountSpecified), isWrapping);

        if (isWrapping) {
            poolManager.take(underlyingCurrency, address(this), inputAmount);
            uint256 wrappedAmount = deposit(inputAmount);
            _settle(wrapperCurrency, wrappedAmount);
            int128 amountUnspecified = isExactInput ? int128(int256(wrappedAmount)) : -int128(int256(inputAmount));
            swapDelta = toBeforeSwapDelta(-int128(params.amountSpecified), amountUnspecified);
        } else {
            poolManager.take(wrapperCurrency, address(this), inputAmount);
            uint256 unwrappedAmount = withdraw(inputAmount);
            _settle(underlyingCurrency, unwrappedAmount);
            int128 amountUnspecified = isExactInput ? int128(int256(unwrappedAmount)) : -int128(int256(inputAmount));
            swapDelta = toBeforeSwapDelta(-int128(params.amountSpecified), amountUnspecified);
        }

        return (IHooks.beforeSwap.selector, swapDelta, 0);
    }

    /// @notice Deposits underlying tokens to receive wrapper tokens
    /// @param underlyingAmount The amount of underlying tokens to deposit
    /// @return wrapperAmount The amount of wrapper tokens received
    /// @dev Implementing contracts should handle the wrapping operation
    ///      The base contract will handle settling tokens with the pool manager
    function deposit(uint256 underlyingAmount) internal virtual returns (uint256 wrapperAmount);

    /// @notice Withdraws wrapper tokens to receive underlying tokens
    /// @param wrapperAmount The amount of wrapper tokens to withdraw
    /// @return underlyingAmount The amount of underlying tokens received
    /// @dev Implementing contracts should handle the unwrapping operation
    ///      The base contract will handle settling tokens with the pool manager
    function withdraw(uint256 wrapperAmount) internal virtual returns (uint256 underlyingAmount);

    /// @notice Calculates the required input amount for a desired output amount
    /// @param amountOut The desired output amount
    /// @param isWrapping True if wrapping (underlying -> wrapper), false if unwrapping
    /// @return The required input amount
    /// @dev Default implementation assumes 1:1 ratio between wrapper and underlying
    /// @dev Override this function for wrappers with different exchange rates
    /// @dev Used for exact output swaps to determine how much input is needed
    function _getInputRequired(uint256 amountOut, bool isWrapping) internal view virtual returns (uint256) {
        // default to 1:1 ratio
        return amountOut;
    }

    /// @notice Helper function to determine if the swap is wrapping underlying to wrapper tokens
    /// @param poolKey The pool being used for the swap
    /// @param zeroForOne The direction of the swap
    /// @return True if swapping underlying to wrapper, false if unwrapping
    function _isWrapping(PoolKey calldata poolKey, bool zeroForOne) internal view returns (bool) {
        Currency inputCurrency = zeroForOne ? poolKey.currency0 : poolKey.currency1;
        return inputCurrency == underlyingCurrency;
    }

    /// @notice Settles tokens with the pool manager after a wrap/unwrap operation
    /// @param currency The currency being settled (wrapper or underlying)
    /// @param amount The amount of tokens to settle
    /// @dev Handles both native currency (ETH) and ERC20 tokens:
    ///      - For native currency: Uses settle with value
    ///      - For ERC20: Syncs pool state, transfers tokens, then settles
    function _settle(Currency currency, uint256 amount) internal {
        if (currency.isAddressZero()) {
            poolManager.settle{value: amount}();
        } else {
            poolManager.sync(currency);
            currency.transfer(address(poolManager), amount);
            poolManager.settle();
        }
    }
}
