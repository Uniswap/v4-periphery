// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseHook} from "../../BaseHook.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";

abstract contract FeeTaker is BaseHook {
    using SafeCast for uint256;

    bytes internal constant ZERO_BYTES = bytes("");

    constructor(IPoolManager _poolManager) BaseHook(_poolManager) {}

    /**
     * @notice This hook takes a fee from the unspecified token after a swap.
     * @dev This can be overridden if more permissions are needed.
     */
    function getHookPermissions() public pure virtual override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: false,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: true,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    function afterSwap(
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata hookData
    ) external override onlyByManager returns (bytes4, int128) {
        //(Currency currencyUnspecified, amountUnspecified) = key.getUnspecified(params);

        // fee will be in the unspecified token of the swap
        bool currency0Specified = (params.amountSpecified < 0 == params.zeroForOne);
        (Currency currencyUnspecified, int128 amountUnspecified) =
            (currency0Specified) ? (key.currency1, delta.amount1()) : (key.currency0, delta.amount0());
        // if exactOutput swap, get the absolute output amount
        if (amountUnspecified < 0) amountUnspecified = -amountUnspecified;

        uint256 feeAmount = _feeAmount(amountUnspecified);
        // mint ERC6909 instead of take to avoid edge case where PM doesn't have enough balance
        manager.mint(address(this), CurrencyLibrary.toId(currencyUnspecified), feeAmount);

        (bytes4 selector, int128 amount) = _afterSwap(sender, key, params, delta, hookData);
        return (selector, feeAmount.toInt128() + amount);
    }

    function withdraw(Currency[] calldata currencies) external {
        manager.unlock(abi.encode(currencies));
    }

    function _unlockCallback(bytes calldata rawData) internal override returns (bytes memory) {
        Currency[] memory currencies = abi.decode(rawData, (Currency[]));
        uint256 length = currencies.length;
        for (uint256 i = 0; i < length;) {
            uint256 amount = manager.balanceOf(address(this), CurrencyLibrary.toId(currencies[i]));
            manager.burn(address(this), CurrencyLibrary.toId(currencies[i]), amount);
            manager.take(currencies[i], _recipient(), amount);
            unchecked {
                ++i;
            }
        }
        return ZERO_BYTES;
    }

    /**
     * @dev This is a virtual function that should be overridden so it returns the fee charged for a given amount.
     */
    function _feeAmount(int128 amountUnspecified) internal view virtual returns (uint256);

    /**
     * @dev This is a virtual function that should be overridden so it returns the address to receive the fee.
     */
    function _recipient() internal view virtual returns (address);

    /**
     * @dev This can be overridden to add logic after a swap.
     */
    function _afterSwap(address, PoolKey memory, IPoolManager.SwapParams memory, BalanceDelta, bytes calldata)
        internal
        virtual
        returns (bytes4, int128)
    {
        return (BaseHook.afterSwap.selector, 0);
    }
}
